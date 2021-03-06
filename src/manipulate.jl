## manipulate to go here
using Mustache


## make_control
##
## maps a tuple to a control
## The tuple has the form:
## (:nm, values..., {:label=>"label", :initial=>"initial", :control=>"slider"})
## where the ending `Dict` is optional
## 
## By default, the initial symbol, `:nm`, represents an unbound variable in
## the manipulated expression. During the evaluation of the
## expression, its value comes from the control.
##
## The `values...` is used to specify the range of acceptable values or type of value. The 

## (:nm, Bool) -> checkbox
make_control(parent::Container, x::Bool) = checkbox(parent, x)

## (:nm, Range) -> slider
function make_control(parent::Container, x::Union(Range, Range1, Ranges)) 
    obj = slider(parent, x)
    obj[:size] = [100, 20]
    obj
end

## (:nm, Range, Range) -> 2dslider
make_control(parent::Container, x::Union(Range, Range1,Ranges), y::Union(Range, Range1,Ranges)) = slider2d(parent, x, y)

## (:nm, Vector) -> length <= 3 -> radio else combo. (Can be buttongroup, slider, listbox, ...
function make_control(parent::Container, x::Vector)
    if length(x) <= 3
        radiogroup(parent, x, orientation=:vertical)
    else
        cb = combobox(parent, x)
        cb[:value] = cb.model.items[1] # initialize
        cb
    end
end

## (:nm, String) -> edit
make_control(parent::Container, x::String) = lineedit(parent, x)


## (:nm, Real) -> edit with coercion
make_control(parent::Container, x::Real) = lineedit(parent, x, coerce=parsefloat)
## (:nm, Int) -> edit with coercion
make_control(parent::Container, x::Int) = lineedit(parent, x, coerce=parseint)


## evaluation context
## context to store dynamic values
module ManipulateContext
end

function dict_to_module(d::Dict, context) ## stuff values into Manipulate Context
    for (k,v) in d
        eval(context, :($(symbol(k)) = $v))
    end
end


## The main manipulate object and some methods
type ManipulateObject
    expr
    controls
    window
    output_area
    toolkit
end

manipulate_signal(x) = "valueChanged"
manipulate_signal(x::LineEdit) = "editingFinished"

setsize(object::ManipulateObject, sz::Vector) = setsize(object.toolkit, object.window, sz)
function getValue(object::ManipulateObject)
    d = Dict()
    for (k, v) in object.controls
        if !isa(v, Button)
            d[k] = getValue(v)
        end
    end
    d
end

## set GUI value for symbol to value
function setValue(object::ManipulateObject, key::Symbol, value)
    ## get id from controls
    ctrl = filter(u -> isa(u, MControlType) && u.nm == key, object.controls)
    if length(ctrl) > 0
        setValue(object.toolkit, ctrl[1], value)
    end
end
## Give [] interface to values
import Base: getindex, setindex!
function getindex(object::ManipulateObject, x::Symbol)
    ctrl = filter(u -> isa(u, MControlType) && u.nm == x, object.controls)
    length(ctrl) > 0 ? getValue(object.toolkit, ctrl[1]) : nothing
end
setindex!(object::ManipulateObject, value,  x::Symbol) = setValue(object, x, value)

ClearDisplay(self::ManipulateObject) = ClearDisplay(self.toolkit, self)




## Manipulate an expression with controls specified by args...
## 
## `expr`: an expression to manipulate. Last value computed is
## displayed.  Variables in the expression can refer to symbols
## specified through the args.... These are replaced with the values
## generated by the GUI. Expressions are easily created with `quote`
## blocks, though there are some subtle issues, such as loading of
## modules.
##
## Expressions which return `Winston` objects are plotted, others are
## displayed as text objects after coercion by the `string` method.
##
## `args...`: A collection of control specifications. These can be
## simple specification, such as (:n, 1:10) which would map to a
## slider for the symbol n. There are other familiar control types
## without a shortcut, such as `MInput` for text input.
##
## Keyword arguments:
##
## `toolkit`: MIME specification of toolkit,
## eg. `MIME("application/x-tcltk")`
##
## `title`: title for window
##
## `control_placement`: a symbol, `:left` or `top` to indicate where
## output window should go.
##
## `modules`: A vector of symbols listing needed modules to load. One
## can't call `using ModuleName` within the expression to manipulate.
##
## Output:
##
## Creates a window with controls to manipulate the expression. The
## return value is of type `ManipulateObject`.
function manipulate(expr, args...; 
                    toolkit::MIME=default_toolkit, ##MIME("application/x-tcltk"),
                    title::String="Manipulate",
                    control_placement::Symbol=:left, ## or :left  
                    modules::Vector=[],              # eg. [:Winston, :SymPy]
                    width::Int=600,
                    height::Int=400,
                    kwargs...)

    controls = Any[]
    self = ManipulateObject(expr, controls, nothing, nothing, toolkit)

    ## should provide per instance context
    context = ManipulateContext

    for i in modules
        f = "manipulate-$(string(i)).jl"
        if isfile(f)
            require(f)
        end
        eval(context, Expr(:using, i))
    end

    eval(context, :($(:self) = $self))


    function update_gui(value)
        ## need to push these into context
        d = getValue(self)
        dict_to_module(d, context)
        p = eval(context, expr)
        if !isa(p, Nothing)
            Display(toolkit, self, p, context=context) 
        end
    end

    set_these = Dict()

    controls = Dict()
    
    ## layout
    self.window = w = window(toolkit=toolkit, title=title, size=[width, height], visible=false)
    istk() && Tk.pack_stop_propagate(w[:widget])

    f = hbox(w)
    push!(w, f)
    
    lb = vbox(f)
    lb[:sizepolicy] = (:fixed, :fixed)
    lb[:alignment] = (:left, :top)

    self.output_area = rb = vbox(f)
    rb[:sizepolicy] = (:expand, :expand)
    isqt() && push!(rb, pyplotgraphic(rb))

    push!(f, lb)
    push!(f, rb)
    
    fl = formlayout(lb)
    fl[:sizepolicy] = (:expand, :fixed)
    for ctrl in args
        if isa(ctrl, Tuple)
            nm = ctrl[1]
            isa(nm, Symbol) || error("Initial value of a control is a symbol")
            ## do we have a dict? does it have a control?
            d = ctrl[end]
            if isa(ctrl[end], Dict) && haskey(d, :control)
                widget = d[:control](fl, ctrl[2:end-1]...)
            elseif isa(ctrl[end], Dict) && !haskey(d, :control)
                widget = make_control(fl, ctrl[2:end-1]...)
            else
                widget = make_control(fl, ctrl[2:end]...)
            end

            ## initial
            if isa(d, Dict) && haskey(d, :initial)
                set_these[nm] = d[:initial]
            end
            ## label {:label=>"string"} {:label=>nothing} or skip to get string(:nm)
            label = (isa(d, Dict) && haskey(d, :label)) ? d[:label] : string(ctrl[1])

            connect(widget, manipulate_signal(widget), update_gui)
            push!(fl, widget, label)
            controls[nm] = widget
        elseif isa(ctrl, String)
            if ctrl == "----"
                push!(fl, separator(fl), nothing)
            else
                push!(fl, label(fl, ctrl), nothing)
            end
        else

            error("What is this doing here?")
        end
    end
    
    push!(lb, fl)

    self.controls = controls
    [setValue(self, k, v) for (k, v) in set_these] # initialize any values
    raise(w)
    update_gui(nothing)

    self.window[:visible] = true
    self
end

