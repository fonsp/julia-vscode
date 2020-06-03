module _vscodeserver

using REPL, Sockets, Base64, Pkg, UUIDs
import Base: display, redisplay
import Dates

include("../languageserver/packages/JSON/src/JSON.jl")
include("../packages/OrderedCollections/src/OrderedCollections.jl")
include("../debugger/packages/CodeTracking/src/CodeTracking.jl")

module JuliaInterpreter
    using ..CodeTracking

    include("../debugger/packages/JuliaInterpreter/src/core.jl")
end

module LoweredCodeUtils
    using ..JuliaInterpreter
    using ..JuliaInterpreter: SSAValue, SlotNumber, Frame
    using ..JuliaInterpreter: @lookup, moduleof, pc_expr, step_expr!, is_global_ref, is_quotenode, whichtt,
                        next_until!, finish_and_return!, get_return, nstatements, codelocation


    include("../packages/LoweredCodeUtils/src/core.jl")
end

module Revise
    using ..OrderedCollections
    using ..CodeTracking
    using ..JuliaInterpreter
    using ..LoweredCodeUtils

    using ..CodeTracking: PkgFiles, basedir, srcfiles
    using ..JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return
    using ..JuliaInterpreter: @lookup, moduleof, scopeof, pc_expr, prepare_thunk, split_expressions,
                        linetable, codelocs, LineTypes
    using ..LoweredCodeUtils: next_or_nothing!, isanonymous_typedef
    using ..CodeTracking: line_is_decl
    using ..JuliaInterpreter: is_global_ref
    using ..CodeTracking: basepath


    include("../packages/Revise/src/core.jl")
end

module JSONRPC
    import ..JSON
    import ..UUIDs

    include("../packages/JSONRPC/src/core.jl")
end

include("gridviewer.jl")

include("repl.jl")
include("../debugger/debugger.jl")

struct InlineDisplay <: AbstractDisplay end

repl_pipename = Base.ARGS[1]

!(Sys.isunix() || Sys.iswindows()) && error("Unknown operating system.")

function ends_with_semicolon(x)
    return REPL.ends_with_semicolon(split(x,'\n',keepempty = false)[end])
end

repl_conn = connect(repl_pipename)

conn_endpoint = JSONRPC.JSONRPCEndpoint(repl_conn, repl_conn)

function sendDisplayMsg(kind, data)
    JSONRPC.send_notification(conn_endpoint, "display", Dict{String,String}("kind"=>kind, "data"=>data))
end

function strlimit(str::AbstractString, limit::Int = 30, ellipsis::AbstractString = "…")
    will_append = length(str) > limit

    io = IOBuffer()
    i = 1
    for c in str
        will_append && i > limit - length(ellipsis) && break
        isvalid(c) || continue

        print(io, c)
        i += 1
    end
    will_append && print(io, ellipsis)

    return String(take!(io))
end

"""
    render(x)

Produce a representation of `x` that can be displayed by a UI. Must return a dictionary with
the following fields:
- `inline`: Short one-line plain text representation of `x`. Typically limited to 100 characters.
- `all`: Plain text string (that may contain linebreaks and other signficant whitespace) to further describe `x`.
- `iserr`: Boolean. The frontend may style the UI differently depending on this value.
"""
function render(x)
    str = filter(isvalid, strlimit(sprint(io -> Base.invokelatest(show, IOContext(io, :limit => true, :color => false, :displaysize => (100, 64)), MIME"text/plain"(), x)), 10_000))

    return Dict(
        "inline" => strlimit(first(split(str, "\n")), 100),
        "all" => str,
        "iserr" => false
    )
end

function render(::Nothing)
    return Dict(
        "inline" => "✓",
        "all" => "nothing",
        "iserr" => false
    )
end

struct EvalError
    err
    bt
end

function render(err::EvalError)
    str = filter(isvalid, strlimit(sprint(io -> Base.invokelatest(Base.display_error, IOContext(io, :limit => true, :color => false, :displaysize => (100, 64)), err.err, err.bt)), 10_000))

    return Dict(
        "inline" => strlimit(first(split(str, "\n")), 100),
        "all" => str,
        "iserr" => true
    )
end
"""
    safe_render(x)

Calls `render`, but catches errors in the display system.
"""
function safe_render(x)
    try
        render(x)
    catch err
        out = render(EvalError(err, catch_backtrace()))
        out["inline"] = string("Display Error: ", out["inline"])
        out["all"] = string("Display Error: ", out["all"])
    end
end

function module_from_string(mod)
    ms = split(mod, '.')

    out = Main

    loaded_module = findfirst(==(first(ms)), string.(Base.loaded_modules_array()))

    if loaded_module !== nothing
        out = Base.loaded_modules_array()[loaded_module]
        popfirst!(ms)
    end

    for m in Symbol.(ms)
        if isdefined(out, m)
            resolved = getfield(out, m)

            if resolved isa Module
                out = resolved
            else
                return out
            end
        end
    end

    return out
end

is_module_loaded(mod) = mod == "Main" || module_from_string(mod) !== Main

function get_modules(toplevel = nothing, mods = Set(Module[]))
    top_mods = toplevel === nothing ? Base.loaded_modules_array() : [toplevel]

    for mod in top_mods
        push!(mods, mod)

        for name in names(mod, all=true)
            if !Base.isdeprecated(mod, name) && isdefined(mod, name)
                thismod = getfield(mod, name)
                if thismod isa Module && thismod !== mod && !(thismod in mods)
                    push!(mods, thismod)
                    get_modules(thismod, mods)
                end
            end
        end
    end
    mods
end

run(conn_endpoint)

@async begin

    while true
        msg = JSONRPC.get_next_message(conn_endpoint)

        if msg["method"] == "repl/runcode"
            params = msg["params"]


            source_filename = params["filename"]
            code_line = params["line"]
            code_column = params["column"]
            source_code = params["code"]
            mod = params["module"]

            resolved_mod = try
                module_from_string(mod)
            catch err
                # maybe trigger error reporting here
                Main
            end

            show_code = params["showCodeInREPL"]
            show_result = params["showResultInREPL"]

            hideprompt() do
                let mode = get(ENV, "JULIA_REVISE", "auto")
                    mode == "auto" && Revise.revise()
                end
                if show_code
                    for (i,line) in enumerate(eachline(IOBuffer(source_code)))
                        if i==1
                            printstyled("julia> ", color=:green)
                            print(' '^code_column)
                        else
                            # Indent by 7 so that it aligns with the julia> prompt
                            print(' '^7)
                        end

                        println(line)
                    end
                end

                withpath(source_filename) do
                    res = try
                        Base.invokelatest(include_string, resolved_mod, '\n'^code_line * ' '^code_column *  source_code, source_filename)
                    catch err
                        EvalError(err, catch_backtrace())
                    end

                    if show_result
                        if res isa EvalError
                            Base.display_error(stderr, res.err, res.bt)
                        elseif res !== nothing && !ends_with_semicolon(source_code)
                            Base.invokelatest(display, res)
                        end
                    else
                        try
                            Base.invokelatest(display, InlineDisplay(), res)
                        catch err
                            if !(err isa MethodError)
                                printstyled(stderr, "Display Error: ", color = Base.error_color(), bold = true)
                                Base.display_error(stderr, err, catch_backtrace())
                            end
                        end
                    end

                    JSONRPC.send_success_response(conn_endpoint, msg, safe_render(res))
                end
            end
        elseif msg["method"] == "repl/loadedModules"
            JSONRPC.send_success_response(conn_endpoint, msg, string.(collect(get_modules())))
        elseif msg["method"] == "repl/isModuleLoaded"
            mod = msg["params"]

            is_loaded = is_module_loaded(mod)

            JSONRPC.send_success_response(conn_endpoint, msg, is_loaded)
        elseif msg["method"] == "repl/startdebugger"
            hideprompt() do
                debug_pipename = msg["params"]
                try
                    VSCodeDebugger.startdebug(debug_pipename)
                catch err
                    VSCodeDebugger.global_err_handler(err, catch_backtrace(), ARGS[4], "Debugger")
                end
            end
        end
    end
end

function display(d::InlineDisplay, ::MIME{Symbol("image/png")}, x)
    payload = stringmime(MIME("image/png"), x)
    sendDisplayMsg("image/png", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("image/png")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("image/svg+xml")}, x)
    payload = stringmime(MIME("image/svg+xml"), x)
    sendDisplayMsg("image/svg+xml", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("image/svg+xml")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("text/html")}, x)
    payload = stringmime(MIME("text/html"), x)
    sendDisplayMsg("text/html", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("text/html")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("juliavscode/html")}, x)
    payload = stringmime(MIME("juliavscode/html"), x)
    sendDisplayMsg("juliavscode/html", payload)
end

Base.Multimedia.istextmime(::MIME{Symbol("juliavscode/html")}) = true

displayable(d::InlineDisplay, ::MIME{Symbol("juliavscode/html")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v2+json")}, x)
    payload = stringmime(MIME("application/vnd.vegalite.v2+json"), x)
    sendDisplayMsg("application/vnd.vegalite.v2+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v2+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v3+json")}, x)
    payload = stringmime(MIME("application/vnd.vegalite.v3+json"), x)
    sendDisplayMsg("application/vnd.vegalite.v3+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v3+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v4+json")}, x)
    payload = stringmime(MIME("application/vnd.vegalite.v4+json"), x)
    sendDisplayMsg("application/vnd.vegalite.v4+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vegalite.v4+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v3+json")}, x)
    payload = stringmime(MIME("application/vnd.vega.v3+json"), x)
    sendDisplayMsg("application/vnd.vega.v3+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v3+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v4+json")}, x)
    payload = stringmime(MIME("application/vnd.vega.v4+json"), x)
    sendDisplayMsg("application/vnd.vega.v4+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v4+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v5+json")}, x)
    payload = stringmime(MIME("application/vnd.vega.v5+json"), x)
    sendDisplayMsg("application/vnd.vega.v5+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.vega.v5+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.plotly.v1+json")}, x)
    payload = stringmime(MIME("application/vnd.plotly.v1+json"), x)
    sendDisplayMsg("application/vnd.plotly.v1+json", payload)
end

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.dataresource+json")}) = true

function display(d::InlineDisplay, ::MIME{Symbol("application/vnd.dataresource+json")}, x)
    payload = stringmime(MIME("application/vnd.dataresource+json"), x)
    sendDisplayMsg("application/vnd.dataresource+json", payload)
end

Base.Multimedia.istextmime(::MIME{Symbol("application/vnd.dataresource+json")}) = true

displayable(d::InlineDisplay, ::MIME{Symbol("application/vnd.plotly.v1+json")}) = true

function display(d::InlineDisplay, x)
    if showable("application/vnd.vegalite.v4+json", x)
        display(d,"application/vnd.vegalite.v4+json", x)
    elseif showable("application/vnd.vegalite.v3+json", x)
        display(d,"application/vnd.vegalite.v3+json", x)
    elseif showable("application/vnd.vegalite.v2+json", x)
        display(d,"application/vnd.vegalite.v2+json", x)
    elseif showable("application/vnd.vega.v5+json", x)
        display(d,"application/vnd.vega.v5+json", x)
    elseif showable("application/vnd.vega.v4+json", x)
        display(d,"application/vnd.vega.v4+json", x)
    elseif showable("application/vnd.vega.v3+json", x)
        display(d,"application/vnd.vega.v3+json", x)
    elseif showable("application/vnd.plotly.v1+json", x)
        display(d,"application/vnd.plotly.v1+json", x)
    elseif showable("juliavscode/html", x)
        display(d,"juliavscode/html", x)
    # elseif showable("text/html", x)
    #     display(d,"text/html", x)
    elseif showable("image/svg+xml", x)
        display(d,"image/svg+xml", x)
    elseif showable("image/png", x)
        display(d,"image/png", x)
    else
        throw(MethodError(display,(d,x)))
    end
end

function _display(d::InlineDisplay, x)
    if showable("application/vnd.dataresource+json", x)
        display(d, "application/vnd.dataresource+json", x)
    else
        try
            display(d, x)
        catch err
            if err isa MethodError
                @warn "Cannot display values of type $(typeof(x)) in VS Code."
            else
                rethrow(err)
            end
        end
    end
end

if length(Base.ARGS) >= 3 && Base.ARGS[3] == "true"
    atreplinit(i->Base.Multimedia.pushdisplay(InlineDisplay()))
end

# Load revise?
load_revise = Base.ARGS[2] == "true"

const tabletraits_uuid = UUIDs.UUID("3783bdb8-4a98-5b6b-af9a-565f29a5fe9c")
const datavalues_uuid = UUIDs.UUID("e7dc6d0d-1eca-5fa6-8ad6-5aecde8b7ea5")

global _isiterabletable = i -> false
global _getiterator = i -> i

function pkgload(pkg)
    if pkg.uuid==tabletraits_uuid
        x = Base.require(pkg)

        global _isiterabletable = x.isiterabletable
        global _getiterator = x.getiterator
    elseif pkg.uuid==datavalues_uuid
        x = Base.require(pkg)

        eval(quote
            function JSON_print_escaped(io, val::$(x.DataValue))
                $(x.isna)(val) ? print(io, "null") : JSON_print_escaped(io, val[])
            end

            julia_type_to_schema_type(::Type{T}) where {S, T<:$(x.DataValue){S}} = julia_type_to_schema_type(S)
        end)
    end
end

push!(Base.package_callbacks, pkgload)

function remove_lln!(ex::Expr)
    for i in length(ex.args):-1:1
        if ex.args[i] isa LineNumberNode
            deleteat!(ex.args, i)
        elseif ex.args[i] isa Expr
            remove_lln!(ex.args[i])
        end
    end
end

end

function vscodedisplay(x)
    if showable("application/vnd.dataresource+json", x)
        _vscodeserver._display(_vscodeserver.InlineDisplay(), x)
    elseif _vscodeserver._isiterabletable(x)===true
        buffer = IOBuffer()
        io = IOContext(buffer, :compact=>true)
        _vscodeserver.printdataresource(io, _vscodeserver._getiterator(x))
        buffer_asstring = _vscodeserver.CachedDataResourceString(String(take!(buffer)))
        _vscodeserver._display(_vscodeserver.InlineDisplay(), buffer_asstring)
    elseif _vscodeserver._isiterabletable(x)===missing
        try
            buffer = IOBuffer()
            io = IOContext(buffer, :compact=>true)
            _vscodeserver.printdataresource(io, _vscodeserver._getiterator(x))
            buffer_asstring = _vscodeserver.CachedDataResourceString(String(take!(buffer)))
            _vscodeserver._display(_vscodeserver.InlineDisplay(), buffer_asstring)
        catch err
            _vscodeserver._display(_vscodeserver.InlineDisplay(), x)
        end
    elseif x isa AbstractVector || x isa AbstractMatrix
        buffer = IOBuffer()
        io = IOContext(buffer, :compact=>true)
        _vscodeserver.print_array_as_dataresource(io, _vscodeserver._getiterator(x))
        buffer_asstring = _vscodeserver.CachedDataResourceString(String(take!(buffer)))
        _vscodeserver._display(_vscodeserver.InlineDisplay(), buffer_asstring)
    else
        _vscodeserver._display(_vscodeserver.InlineDisplay(), x)
    end
end

vscodedisplay() = i -> vscodedisplay(i)

if _vscodeserver.load_revise
    try
        @eval using Revise
        _vscodeserver.Revise.async_steal_repl_backend()
    catch err
    end
end

macro enter(command)
    _vscodeserver.remove_lln!(command)
    :(_vscodeserver.JSONRPC.send_notification(_vscodeserver.conn_endpoint, "debugger/enter", $(string(command))))
end

macro run(command)
    _vscodeserver.remove_lln!(command)
    :(_vscodeserver.JSONRPC.send_notification(_vscodeserver.conn_endpoint, "debugger/run", $(string(command))))
end
