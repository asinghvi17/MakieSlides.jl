module MakieSlides


using CairoMakie, GLMakie
using Markdown
using Makie
using Printf
import Cairo


# Makie internal dependencies of formattedtext.jl
import Makie: NativeFont, gl_bboxes
import MakieCore: automatic


# Makie internal dependencies of formattedlabel.jl, formattedlist, markdownbox.jl
using Makie.MakieLayout
import Makie.MakieLayout: @Block, inherit, round_to_IRect2D, initialize_block!
# import Makie.MakieLayout: @Layoutable, layoutable, get_topscene,
#                           @documented_attributes, lift_parent_attribute, docvarstring,
#                           subtheme, LayoutObservables, round_to_IRect2D
# using Makie.GridLayoutBase


# export Slide, slidetext!, slideheader!, slidefooter!, 
export Presentation, add_slide!, reset!, save
export formattedtext, formattedtext!
export FormattedLabel
# export FormattedLabel, FormattedList, FormattedTable, MarkdownBox


include("formattedtext.jl")
include("formattedlabel.jl")
# include("formattedlist.jl")
# include("formattedtable.jl")
# include("markdownbox.jl")


mutable struct Presentation
    parent::Figure
    fig::Figure

    idx::Int
    slides::Vector{Function}
    clear::Vector{Bool}
    locked::Bool
end

"""
    Presentation(; kwargs...)

Creates a `pres::Presentation` with two figures `pres.parent` and `pres.fig`. 
The former remains static during the presentation and acts as the background and 
window.  The latter acts as the slide and gets cleared and reassambled every 
time a new slide is requested. (This includes events.)

To add a slide use:

    add_slide!(pres[, clear = true]) do fig
        # Plot your slide to fig
    end

Note that `add_slide!` immediately switches to and draws the newly added slide. 
This is done to get rid of compilation times beforehand.

To switch to a different slide:
- `next_slide!(pres)`: Advance to the next slide. Default keys: Keyboard.right, Keyboard.enter
- `previous_slide!(pres)`: Go to the previous slide. Default keys: Keyboard.left
- `reset!(pres)`: Go to the first slide. Defaults keys: Keyboard.home
- `set_slide_idx!(pres, idx)`: Go a specified slide.

"""
function Presentation(; kwargs...)
    # This is a modified version of the Figure() constructor.
    parent = Figure(; kwargs...)
    # translate!(parent.scene, 0, 0, 1) # more will be incompatible with space = :relative

    kwargs_dict = Dict(kwargs)
    padding = pop!(kwargs_dict, :figure_padding, Makie.current_default_theme()[:figure_padding])

    # Separate events from the parent (static background) and slide figure so
    # that slide events can be cleared without clearing slide events (like 
    # moving to the next slide)
    separated_events = Events()
    _events = parent.scene.events
    for fieldname in fieldnames(Events)
        obs = getfield(separated_events, fieldname)
        if obs isa Makie.AbstractObservable
            on(v -> obs[] = v, getfield(_events, fieldname), priority = 100)
        end
    end

    scene = Scene(
        parent.scene; camera=campixel!, clear = false, 
        events = separated_events, kwargs_dict...
    )

    padding = padding isa Observable ? padding : Observable{Any}(padding)
    alignmode = lift(Outside ∘ Makie.to_rectsides, padding)

    layout = Makie.GridLayout(scene)

    on(alignmode) do al
        layout.alignmode[] = al
        Makie.GridLayoutBase.update!(layout)
    end
    notify(alignmode)

    f = Figure(
        scene,
        layout,
        [],
        Attributes(),
        Ref{Any}(nothing)
    )
    layout.parent = f

    p = Presentation(parent, f, 1, Function[], Bool[], false)

    # Interactions
    on(events(parent.scene).keyboardbutton, priority = -1) do event
        if event.action == Keyboard.release
            if event.key in (Keyboard.right, Keyboard.enter)
                next_slide!(p)
            elseif event.key in (Keyboard.left,)
                previous_slide!(p)
            elseif event.key in (Keyboard.home,)
                reset!(p)
            end
        end
    end

    return p
end

function _set_slide_idx!(p::Presentation, i)
    # Moving through slides quickly seems to sometimes trigger plot insertion 
    # before or during the `empty!(p.fig)` procedure. This causes emptying to
    # fail and leaves orphaned plots behind. To avoid this we have a lock here
    # which disables slide changes until the previous change is finished.
    if !p.locked && i != p.idx && (1 <= i <= length(p.slides))
        p.locked = true
        p.idx = i
        p.clear[p.idx] && empty!(p.fig)
        p.slides[p.idx](p.fig)
        p.locked = false
    end
    return
end

function set_slide_idx!(p::Presentation, i)
    # If we jump randomly we need to start from the last cleared fig and build
    # the current slide up from there.
    if p.clear[i]
        _set_slide_idx!(p, i)
    else
        idx = i
        while !p.clear[idx] && idx > 1
            idx -= 1
        end
        for j in idx:i
            _set_slide_idx!(p, j)
        end
    end
    return
end


Base.display(p::Presentation) = display(p.parent)
Base.length(p::Presentation) = length(p.slides)
Base.eachindex(p::Presentation) = 1:length(p.slides)
next_slide!(p::Presentation) = _set_slide_idx!(p, p.idx + 1)
previous_slide!(p::Presentation) = set_slide_idx!(p, p.idx - 1)
reset!(p::Presentation) = _set_slide_idx!(p, 1)



"""
    add_slide!(f::Function, presentation[, clear = true])

Adds a new slide add the end of the Presentation. If `clear = true` the previous
figure will be reset before drawing.
"""
function add_slide!(f::Function, p::Presentation, clear = true)
    # This is set up to render each slide immediately to get compilation times 
    # out of the way and perhaps catch errors a bit earlier
    try
        clear && empty!(p.fig)
        # with_updates_suspended should stop layouting to trigger when the slide
        # gets set up. This should speed up slide creation a bit.
        with_updates_suspended(() -> f(p.fig), p.fig.layout)
        push!(p.slides, f)
        push!(p.clear, p.idx == 1 || clear) # always clear first slide
        p.idx = length(p.slides)
    catch e
        @error "Failed to add slide - maybe the function signature does not match f(::Presentation)?"
        rethrow(e)
    end
    return
end


#=
function slidetext!(slide, text)
  pane = slide.panes[:content]
  rect = pane.targetlimits[]
  xwidth, ywidth = rect.widths
  xorigin, yorigin = rect.origin
  origin_text = Point2f(xorigin,yorigin+ywidth)
  t = formattedtext!(pane, text, position=origin_text, align=(:left,:top),
                     space=:data, textsize=0.5)
end


function slideheader!(slide, text)
  pane = slide.panes[:header]
  rect = pane.targetlimits[]
  xwidth, ywidth = rect.widths
  xorigin, yorigin = rect.origin
  origin_text = Point2f(xorigin,yorigin+ywidth/2)
  t = formattedtext!(pane, text, position=origin_text, align=(:left,:center),
                     space=:data, textsize=0.5)
end


function slidefooter!(slide, text)
  pane = slide.panes[:footer]
  rect = pane.targetlimits[]
  xwidth, ywidth = rect.widths
  xorigin, yorigin = rect.origin
  origin_text = Point2f(xorigin,yorigin+ywidth/2)
  t = formattedtext!(pane, text, position=origin_text, align=(:left,:center),
                     space=:data, textsize=0.5)
end


Base.display(s::Slide) = display(s.figure)


function save(name, s::Slide)
  CairoMakie.activate!()

  scene = s.figure.scene
  screen = CairoMakie.CairoScreen(scene, name, :pdf)
  CairoMakie.cairo_draw(screen, scene)
  Cairo.finish(screen.surface)

  GLMakie.activate!()
end


Base.@kwdef mutable struct Presentation
  slides::Vector{Slide} = Slide[]
  title::String = ""
  author::String = ""
  slidenumbers::Bool = false
end



function periodic_index(i,N) 
  mod = i % N
  return mod == 0 ? N : mod
end


function Base.display(presentation::Presentation)
  slides = presentation.slides
  @assert length(slides) > 0
  N_slides = length(slides)


  ### Use only one figure and display current slide within slide_pane
  ### Right now this is not possible, because Makie cannot yet move plot objects in between figures
  ### See https://discourse.julialang.org/t/makie-is-there-an-easy-way-to-combine-several-figures-into-a-new-figure-without-re-plotting/64874
  # figure = Figure()
  # figure[1,1] = slide_pane = GridLayout()
  # figure[2,1] = control_pane = GridLayout(tellwidth=false)
  # control_labels = [ "Previous", "Next" ]
  # control_buttons = control_pane[1,1:2] = [ Button(figure, label = l) for l in control_labels ]
  #
  # index = 1
  # on(events(figure).keyboardbutton) do event
  #   # register control button actions
  #   end
  # end
  # show first slide
  # slide_pane = slides[index].figure[1,1]
  # display(figure)

  # Right now we must register events for every slide separately
  for (index, slide) in enumerate(slides)
    on(events(slide.figure).keyboardbutton) do event
      if event.action == Keyboard.press
        index_next = if event.key in (Keyboard.left, Keyboard.h)
          periodic_index(index-1, N_slides)
        elseif event.key in (Keyboard.down, Keyboard.j)
          periodic_index(index-1, N_slides)
        elseif event.key in (Keyboard.right, Keyboard.l)
          periodic_index(index+1, N_slides)
        elseif event.key in (Keyboard.up, Keyboard.k)
          periodic_index(index+1, N_slides)
        # TODO add close window
        else
          @warn "Unused key pressed: $(event.key)"
          index
        end
        display(slides[index_next].figure)
      end
    end
  end
  # show first slide
  display(slides[1])

  return
end
=#

function save(name, presentation::Presentation; aspect=(16,9))
    CairoMakie.activate!()

    @assert length(presentation.slides) > 0

    ratio = aspect[1] / aspect[2]
    width = 1400
    height = width / ratio
    resolution = (width*1.05,height*1.05) # add some border outlines

    scene = presentation.parent.scene
    resize!(scene, resolution)
    screen = CairoMakie.CairoScreen(scene, name, :pdf)

    for idx in eachindex(presentation)
        set_slide_idx!(presentation, idx)
        CairoMakie.cairo_draw(screen, scene)
        Cairo.show_page(screen.context)
        Cairo.restore(screen.context)
    end
    Cairo.finish(screen.surface)

    GLMakie.activate!()
    return
end

# Just to make sure
__init__() = GLMakie.activate!()

end # module
