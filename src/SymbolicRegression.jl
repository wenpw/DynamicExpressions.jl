module SymbolicRegression

# Types
export Population,
    PopMember,
    HallOfFame,
    Options,
    Node,

    #Functions:
    EquationSearch,
    SRCycle,
    calculateParetoFrontier,
    countNodes,
    copyNode,
    printTree,
    stringTree,
    evalTreeArray,
    differentiableEvalTreeArray,
    node_to_symbolic,
    symbolic_to_node,
    custom_simplify,
    simplifyWithSymbolicUtils,
    combineOperators,
    genRandomTree,
    genRandomTreeFixedSize,

    #Operators
    plus,
    sub,
    mult,
    square,
    cube,
    pow,
    div,
    log_abs,
    log2_abs,
    log10_abs,
    log1p_abs,
    acosh_abs,
    sqrt_abs,
    neg,
    greater,
    relu,
    logical_or,
    logical_and,

    # special operators
    gamma,
    erf,
    erfc,
    atanh_clip

using Distributed
import JSON3
using Printf: @printf, @sprintf
using Pkg
using Random: seed!, shuffle!
using FromFile
using Reexport
@reexport using LossFunctions

@from "Core.jl" import CONST_TYPE, MAX_DEGREE, BATCH_DIM, FEATURE_DIM, RecordType, Dataset, Node, copyNode, Options, plus, sub, mult, square, cube, pow, div, log_abs, log2_abs, log10_abs, log1p_abs, sqrt_abs, acosh_abs, neg, greater, greater, relu, logical_or, logical_and, gamma, erf, erfc, atanh_clip, SRConcurrency, SRSerial, SRThreaded, SRDistributed, stringTree, printTree
@from "Utils.jl" import debug, debug_inline, is_anonymous_function, recursive_merge, next_worker, @sr_spawner
@from "EquationUtils.jl" import countNodes
@from "EvaluateEquation.jl" import evalTreeArray, differentiableEvalTreeArray
@from "CheckConstraints.jl" import check_constraints
@from "MutationFunctions.jl" import genRandomTree, genRandomTreeFixedSize, randomNode, randomNodeAndParent, crossoverTrees
@from "LossFunctions.jl" import EvalLoss, Loss, scoreFunc
@from "PopMember.jl" import PopMember, copyPopMember
@from "Population.jl" import Population, bestSubPop, record_population, bestOfSample
@from "HallOfFame.jl" import HallOfFame, calculateParetoFrontier, string_dominating_pareto_curve
@from "SingleIteration.jl" import SRCycle, OptimizeAndSimplifyPopulation
@from "InterfaceSymbolicUtils.jl" import node_to_symbolic, symbolic_to_node
@from "CustomSymbolicUtilsSimplification.jl" import custom_simplify
@from "SimplifyEquation.jl" import simplifyWithSymbolicUtils, combineOperators, simplifyTree
@from "ProgressBars.jl" import ProgressBar, set_multiline_postfix
@from "Recorder.jl" import @recorder, find_iteration_from_record

include("Configure.jl")
include("Deprecates.jl")

StateType{T} = Tuple{
    Union{
        Vector{Vector{Population{T}}},
        Matrix{Population{T}}
    },
    Union{
        HallOfFame,
        Vector{HallOfFame}
    }
}


"""
    EquationSearch(X, y[; kws...])

Perform a distributed equation search for functions `f_i` which
describe the mapping `f_i(X[:, j]) ≈ y[i, j]`. Options are
configured using SymbolicRegression.Options(...),
which should be passed as a keyword argument to options.
One can turn off parallelism with `numprocs=0`,
which is useful for debugging and profiling.

# Arguments
- `X::AbstractMatrix{T}`:  The input dataset to predict `y` from.
    The first dimension is features, the second dimension is rows.
- `y::Union{AbstractMatrix{T}, AbstractVector{T}}`: The values to predict. The first dimension
    is the output feature to predict with each equation, and the
    second dimension is rows.
- `niterations::Int=10`: The number of iterations to perform the search.
    More iterations will improve the results.
- `weights::Union{AbstractMatrix{T}, AbstractVector{T}, Nothing}=nothing`: Optionally
    weight the loss for each `y` by this value (same shape as `y`).
- `varMap::Union{Array{String, 1}, Nothing}=nothing`: The names
    of each feature in `X`, which will be used during printing of equations.
- `options::Options=Options()`: The options for the search, such as
    which operators to use, evolution hyperparameters, etc.
- `numprocs::Union{Int, Nothing}=nothing`:  The number of processes to use,
    if you want `EquationSearch` to set this up automatically. By default
    this will be `4`, but can be any number (you should pick a number <=
    the number of cores available).
- `procs::Union{Array{Int, 1}, Nothing}=nothing`: If you have set up
    a distributed run manually with `procs = addprocs()` and `@everywhere`,
    pass the `procs` to this keyword argument.
- `runtests::Bool=true`: Whether to run (quick) tests before starting the
    search, to see if there will be any problems during the equation search
    related to the host environment.
- `saved_state::Union{StateType, Nothing}=nothing`: If you have already
    run `EquationSearch` and want to resume it, pass the state here.
    To get this to work, you need to have stateReturn=true in the options,
    which will cause `EquationSearch` to return the state. Note that
    you cannot change the operators or dataset, but most other options
    should be changeable.

# Returns
- `hallOfFame::HallOfFame`: The best equations seen during the search.
    hallOfFame.members gives an array of `PopMember` objects, which
    have their tree (equation) stored in `.tree`. Their score (loss)
    is given in `.score`. The array of `PopMember` objects
    is enumerated by size from `1` to `options.maxsize`.
"""
function EquationSearch(X::AbstractMatrix{T}, y::AbstractMatrix{T};
        niterations::Int=10,
        weights::Union{AbstractMatrix{T}, AbstractVector{T}, Nothing}=nothing,
        varMap::Union{Array{String, 1}, Nothing}=nothing,
        options::Options=Options(),
        numprocs::Union{Int, Nothing}=nothing,
        procs::Union{Array{Int, 1}, Nothing}=nothing,
        multithreading::Bool=false,
        runtests::Bool=true,
        saved_state::Union{StateType{T}, Nothing}=nothing,
       ) where {T<:Real}

    nout = size(y, FEATURE_DIM)
    if weights !== nothing
        weights = reshape(weights, size(y))
    end
    datasets = [Dataset(X, y[j, :],
                    weights=(weights === nothing ? weights : weights[j, :]),
                    varMap=varMap)
                for j=1:nout]

    return EquationSearch(datasets;
        niterations=niterations, options=options,
        numprocs=numprocs, procs=procs, multithreading=multithreading,
        runtests=runtests, saved_state=saved_state)
end

function EquationSearch(X::AbstractMatrix{T1}, y::AbstractMatrix{T2}; kw...) where {T1<:Real,T2<:Real}
    U = promote_type(T1, T2)
    EquationSearch(convert(AbstractMatrix{U}, X), convert(AbstractMatrix{U}, y); kw...)
end

function EquationSearch(X::AbstractMatrix{T1}, y::AbstractVector{T2}; kw...) where {T1<:Real,T2<:Real}
    EquationSearch(X, reshape(y, (1, size(y, 1))); kw...)
end

function EquationSearch(datasets::Array{Dataset{T}, 1};
        niterations::Int=10,
        options::Options=Options(),
        numprocs::Union{Int, Nothing}=nothing,
        procs::Union{Array{Int, 1}, Nothing}=nothing,
        multithreading::Bool=false,
        runtests::Bool=true,
        saved_state::Union{StateType{T}, Nothing}=nothing,
       ) where {T<:Real}

                # Population(datasets[j], baselineMSEs[j], npop=options.npop,
                #            nlength=3, options=options, nfeatures=datasets[j].nfeatures),
                # HallOfFame(options),

    noprocs = (procs === nothing && numprocs == 0)
    someprocs = !noprocs

    concurrency = if multithreading
        @assert procs === nothing && numprocs in [0, nothing]
        SRThreaded()
    elseif someprocs
        SRDistributed()
    else #noprocs, multithreading=false
        SRSerial()
    end

    return _EquationSearch(concurrency, datasets;
        niterations=niterations, options=options,
        numprocs=numprocs, procs=procs,
        runtests=runtests, saved_state=saved_state)
end

function _EquationSearch(::ConcurrencyType, datasets::Array{Dataset{T}, 1};
        niterations::Int=10,
        options::Options=Options(),
        numprocs::Union{Int, Nothing}=nothing,
        procs::Union{Array{Int, 1}, Nothing}=nothing,
        runtests::Bool=true,
        saved_state::Union{StateType{T}, Nothing}=nothing,
       ) where {T<:Real,ConcurrencyType<:SRConcurrency}

    can_read_input = true
    try
        Base.start_reading(stdin)
        bytes = bytesavailable(stdin)
        if bytes > 0
            # Clear out initial data
            read(stdin, bytes)
        end
    catch err
        if isa(err, MethodError)
            can_read_input = false
        else
            throw(err)
        end
    end


    # Redefine print, show:
    @eval begin
        Base.print(io::IO, tree::Node) = print(io, stringTree(tree, $options; varMap=$(datasets[1].varMap)))
        Base.show(io::IO, tree::Node) = print(io, stringTree(tree, $options; varMap=$(datasets[1].varMap)))
    end

    example_dataset = datasets[1]
    nout = size(datasets, 1)

    if runtests
        testOptionConfiguration(T, options)
        # Testing the first output variable is the same:
        testDatasetConfiguration(example_dataset, options)
    end

    if example_dataset.weighted
        avgys = [sum(dataset.y .* dataset.weights) / sum(dataset.weights)
                for dataset in datasets]
        baselineMSEs = [Loss(dataset.y, ones(T, dataset.n) .* avgy, dataset.weights, options)
                       for dataset in datasets, avgy in avgys]
    else
        avgys = [sum(dataset.y)/dataset.n for dataset in datasets]
        baselineMSEs = [Loss(dataset.y, ones(T, dataset.n) .* avgy, options)
                       for (dataset, avgy) in zip(datasets, avgys)]
    end

    if options.seed !== nothing
        seed!(options.seed)
    end
    # Start a population on every process
    #    Store the population, hall of fame
    allPopsType = if ConcurrencyType == SRSerial
        Tuple{Population,HallOfFame,RecordType}
    elseif ConcurrencyType == SRDistributed
        Future
    else
        Task
    end

    allPops = [allPopsType[] for j=1:nout]
    init_pops = [allPopsType[] for j=1:nout]
    # Set up a channel to send finished populations back to head node
    if ConcurrencyType in [SRDistributed, SRThreaded]
        if ConcurrencyType == SRDistributed
            channels = [[RemoteChannel(1) for i=1:options.npopulations] for j=1:nout]
        else
            channels = [[Channel(1) for i=1:options.npopulations] for j=1:nout]
        end
        tasks = [Task[] for j=1:nout]
    end

    # This is a recorder for populations, but is not actually used for processing, just
    # for the final return.
    returnPops = [[Population(datasets[j], baselineMSEs[j], npop=1,
                              options=options, nfeatures=datasets[j].nfeatures)
                    for i=1:options.npopulations]
                    for j=1:nout]
    # These initial populations are discarded:
    bestSubPops = [[Population(datasets[j], baselineMSEs[j], npop=1, options=options, nfeatures=datasets[j].nfeatures)
                    for i=1:options.npopulations]
                    for j=1:nout]
    if saved_state === nothing
        hallOfFame = [HallOfFame(options) for j=1:nout]
    else
        hallOfFame = saved_state[2]::Union{HallOfFame, Vector{HallOfFame}}
        if !isa(hallOfFame, Vector{HallOfFame})
            hallOfFame = [hallOfFame]
        end
        hallOfFame::Vector{HallOfFame}
    end
    actualMaxsize = options.maxsize + MAX_DEGREE

    # Make frequencyComplexities a moving average, rather than over all time:
    n_cycles_before_frequency_refresh = 10
    window_size = options.npopulations * options.npop * n_cycles_before_frequency_refresh
    # 3 here means this will last 3 cycles before being "refreshed"
    # We start out with even numbers at all frequencies.
    frequencyComplexities = [ones(T, actualMaxsize) * window_size / actualMaxsize for i=1:nout]

    curmaxsizes = [3 for j=1:nout]
    record = RecordType("options"=>"$(options)")

    if options.warmupMaxsizeBy == 0f0
        curmaxsizes = [options.maxsize for j=1:nout]
    end

    we_created_procs = false
    ##########################################################################
    ### Distributed code:
    ##########################################################################
    if ConcurrencyType == SRDistributed
        if numprocs === nothing && procs === nothing
            numprocs = 4
            procs = addprocs(4)
            we_created_procs = true
        elseif numprocs === nothing
            numprocs = length(procs)
        elseif procs === nothing
            procs = addprocs(numprocs)
            we_created_procs = true
        end

        if we_created_procs
            project_path = splitdir(Pkg.project().path)[1]
            activate_env_on_workers(procs, project_path, options)
            import_module_on_workers(procs, @__FILE__, options)
        end
        move_functions_to_workers(procs, options, example_dataset)
        if runtests
            test_module_on_workers(procs, options)
        end

        if runtests
            test_entire_pipeline(procs, example_dataset, options)
        end
    end
    # Get the next worker process to give a job:
    worker_assignment = Dict{Tuple{Int,Int}, Int}()

    for j=1:nout
        for i=1:options.npopulations
            worker_idx = next_worker(worker_assignment, procs)
            if ConcurrencyType == SRDistributed
                worker_assignment[(j, i)] = worker_idx
            end
            if saved_state === nothing
                new_pop = @sr_spawner ConcurrencyType worker_idx (
                    Population(datasets[j], baselineMSEs[j], npop=options.npop,
                            nlength=3, options=options, nfeatures=datasets[j].nfeatures),
                    HallOfFame(options),
                    RecordType()
                )
            else
                is_vector = typeof(saved_state[1]) <: Vector{Vector{Population{T}}}
                cur_saved_state = is_vector ? saved_state[1][j][i] : saved_state[1][j, i]

                if length(cur_saved_state.members) >= options.npop
                    new_pop = @sr_spawner ConcurrencyType worker_idx (
                        cur_saved_state,
                        HallOfFame(options),
                        RecordType()
                    )
                else
                    # If population has not yet been created (e.g., exited too early)
                    println("Warning: recreating population (output=$(j), population=$(i)), as the saved one only has $(length(cur_saved_state.members)) members.")
                    new_pop = @sr_spawner ConcurrencyType worker_idx (
                        Population(datasets[j], baselineMSEs[j], npop=options.npop,
                                nlength=3, options=options, nfeatures=datasets[j].nfeatures),
                        HallOfFame(options),
                        RecordType()
                    )
                end
            end
            push!(init_pops[j], new_pop)
        end
    end
    # 2. Start the cycle on every process:
    for j=1:nout
        dataset = datasets[j]
        baselineMSE = baselineMSEs[j]
        frequencyComplexity = frequencyComplexities[j]
        curmaxsize = curmaxsizes[j]
        for i=1:options.npopulations
            @recorder record["out$(j)_pop$(i)"] = RecordType()
            worker_idx = next_worker(worker_assignment, procs)
            if ConcurrencyType == SRDistributed
                worker_assignment[(j, i)] = worker_idx
            end

            # TODO - why is this needed??
            # Multi-threaded doesn't like to fetch within a new task:
            updated_pop = @sr_spawner ConcurrencyType worker_idx let
                in_pop = if ConcurrencyType in [SRDistributed, SRThreaded]
                    fetch(init_pops[j][i])[1]
                else
                    init_pops[j][i][1]
                end

                cur_record = RecordType()
                @recorder cur_record["out$(j)_pop$(i)"] = RecordType("iteration0"=>record_population(in_pop, options))
                tmp_pop, tmp_best_seen = SRCycle(dataset, baselineMSE, in_pop,
                                                 options.ncyclesperiteration, curmaxsize,
                                                 copy(frequencyComplexity)/sum(frequencyComplexity),
                                                 verbosity=options.verbosity, options=options,
                                                 record=cur_record)
                tmp_pop = OptimizeAndSimplifyPopulation(dataset, baselineMSE, tmp_pop, options, curmaxsize, cur_record)
                if options.batching
                    for i_member=1:(options.maxsize + MAX_DEGREE)
                        score, loss = scoreFunc(dataset, baselineMSE, tmp_best_seen.members[i_member].tree, options)
                        tmp_best_seen.members[i_member].score = score
                        tmp_best_seen.members[i_member].loss = loss
                    end
                end
                (tmp_pop, tmp_best_seen, cur_record)
            end
            push!(allPops[j], updated_pop)
        end
    end

    debug(options.verbosity > 0 || options.progress, "Started!")
    start_time = time()
    total_cycles = options.npopulations * niterations
    cycles_remaining = [total_cycles for j=1:nout]
    sum_cycle_remaining = sum(cycles_remaining)
    if options.progress && nout == 1
        #TODO: need to iterate this on the max cycles remaining!
        progress_bar = ProgressBar(1:sum_cycle_remaining;
                                   width=options.terminal_width)
        cur_cycle = nothing
        cur_state = nothing
    end

    last_print_time = time()
    num_equations = 0.0
    print_every_n_seconds = 5
    equation_speed = Float32[]

    if ConcurrencyType in [SRDistributed, SRThreaded]
        for j=1:nout
            for i=1:options.npopulations
                # Start listening for each population to finish:
                t = @async put!(channels[j][i], fetch(allPops[j][i]))
                push!(tasks[j], t)
            end
        end
    end

    # Randomly order which order to check populations:
    # This is done so that we do work on all nout equally.
    all_idx = [(j, i) for j=1:nout for i=1:options.npopulations]
    shuffle!(all_idx)
    kappa = 0
    head_node_time = Dict("occupied"=>0, "start"=>time())
    while sum(cycles_remaining) > 0
        kappa += 1
        if kappa > options.npopulations * nout
            kappa = 1
        end
        # nout, npopulations:
        j, i = all_idx[kappa]

        # Check if error on population:
        if ConcurrencyType in [SRDistributed, SRThreaded]
            if istaskfailed(tasks[j][i])
                fetch(tasks[j][i])
                error("Task failed for population")
            end
        end
        # Non-blocking check if a population is ready:
        population_ready = ConcurrencyType in [SRDistributed, SRThreaded] ? isready(channels[j][i]) : true
        # Don't start more if this output has finished its cycles:
        # TODO - this might skip extra cycles?
        population_ready &= (cycles_remaining[j] > 0)
        if population_ready
            head_node_start_work = time()
            # Take the fetch operation from the channel since its ready
            (cur_pop, best_seen, cur_record) = ConcurrencyType in [SRDistributed, SRThreaded] ? take!(channels[j][i]) : allPops[j][i]
            returnPops[j][i] = cur_pop
            cur_pop::Population
            best_seen::HallOfFame
            cur_record::RecordType
            bestSubPops[j][i] = bestSubPop(cur_pop, topn=options.topn)
            @recorder record = recursive_merge(record, cur_record)

            dataset = datasets[j]
            baselineMSE = baselineMSEs[j]
            curmaxsize = curmaxsizes[j]

            #Try normal copy...
            bestPops = Population([member for pop in bestSubPops[j] for member in pop.members])

            ###################################################################
            # Hall Of Fame updating ###########################################
            for (i_member, member) in enumerate(Iterators.flatten((cur_pop.members, best_seen.members[best_seen.exists])))
                part_of_cur_pop = i_member <= length(cur_pop.members)
                size = countNodes(member.tree)

                if part_of_cur_pop
                    frequencyComplexities[j][size] += 1
                end
                actualMaxsize = options.maxsize + MAX_DEGREE


                valid_size = size < actualMaxsize
                if valid_size
                    already_filled = hallOfFame[j].exists[size]
                    better_than_current = member.score < hallOfFame[j].members[size].score
                    if !already_filled || better_than_current
                        hallOfFame[j].members[size] = copyPopMember(member)
                        hallOfFame[j].exists[size] = true
                    end
                end
            end
            ###################################################################

            # Dominating pareto curve - must be better than all simpler equations
            dominating = calculateParetoFrontier(dataset, hallOfFame[j], options)
            hofFile = options.hofFile
            if nout > 1
                hofFile = hofFile * ".out$j"
            end
            open(hofFile, "w") do io
                println(io, "Complexity|MSE|Equation")
                for member in dominating
                    loss = member.loss
                    println(io, "$(countNodes(member.tree))|$(loss)|$(stringTree(member.tree, options, varMap=dataset.varMap))")
                end
            end
            cp(hofFile, hofFile*".bkup", force=true)

            ###################################################################
            # Migration #######################################################
            # Try normal copy otherwise.
            if options.migration
                for k in rand(1:options.npop, round(Int, options.npop*options.fractionReplaced))
                    to_copy = rand(1:size(bestPops.members, 1))

                    # Explicit copy here resets the birth. 
                    cur_pop.members[k] = PopMember(
                        copyNode(bestPops.members[to_copy].tree),
                        copy(bestPops.members[to_copy].score),
                        copy(bestPops.members[to_copy].loss)
                    )
                    # TODO: Clean this up using copyPopMember.
                end
            end

            if options.hofMigration && size(dominating, 1) > 0
                for k in rand(1:options.npop, round(Int, options.npop*options.fractionReplacedHof))
                    # Copy in case one gets used twice
                    to_copy = rand(1:size(dominating, 1))
                    cur_pop.members[k] = PopMember(
                       copyNode(dominating[to_copy].tree),
                       copy(dominating[to_copy].score),
                       copy(dominating[to_copy].loss)
                    )
                    # TODO: Clean this up with copyPopMember.
                end
            end
            ###################################################################

            cycles_remaining[j] -= 1
            if cycles_remaining[j] == 0
                break
            end
            worker_idx = next_worker(worker_assignment, procs)
            if ConcurrencyType == SRDistributed
                worker_assignment[(j, i)] = worker_idx
            end
            @recorder begin
                key = "out$(j)_pop$(i)"
                iteration = find_iteration_from_record(key, record) + 1
            end

            allPops[j][i] = @sr_spawner ConcurrencyType worker_idx let
                cur_record = RecordType()
                @recorder cur_record[key] = RecordType("iteration$(iteration)"=>record_population(cur_pop, options))
                tmp_pop, tmp_best_seen = SRCycle(
                    dataset, baselineMSE, cur_pop, options.ncyclesperiteration,
                    curmaxsize, copy(frequencyComplexities[j])/sum(frequencyComplexities[j]),
                    verbosity=options.verbosity, options=options, record=cur_record)
                tmp_pop = OptimizeAndSimplifyPopulation(dataset, baselineMSE, tmp_pop, options, curmaxsize, cur_record)

                # Update scores if using batching:
                if options.batching
                    for i_member=1:(options.maxsize + MAX_DEGREE)
                        if tmp_best_seen.exists[i_member]
                            score, loss = scoreFunc(dataset, baselineMSE, tmp_best_seen.members[i_member].tree, options)
                            tmp_best_seen.members[i_member].score = score
                            tmp_best_seen.members[i_member].loss = loss
                        end
                    end
                end

                (tmp_pop, tmp_best_seen, cur_record)
            end
            if ConcurrencyType in [SRDistributed, SRThreaded]
                tasks[j][i] = @async put!(channels[j][i], fetch(allPops[j][i]))
            end

            cycles_elapsed = total_cycles - cycles_remaining[j]
            if options.warmupMaxsizeBy > 0
                fraction_elapsed = 1f0 * cycles_elapsed / total_cycles
                if fraction_elapsed > options.warmupMaxsizeBy
                    curmaxsizes[j] = options.maxsize
                else
                    curmaxsizes[j] = 3 + floor(Int, (options.maxsize - 3) * fraction_elapsed / options.warmupMaxsizeBy)
                end
            end
            num_equations += options.ncyclesperiteration * options.npop / 10.0

            if options.progress && nout == 1
                # set_postfix(iter, Equations=)
                equation_strings = string_dominating_pareto_curve(hallOfFame[j], baselineMSE,
                                                                  datasets[j], options,
                                                                  avgys[j])
                load_string = @sprintf("Head worker occupation: %.1f", 100*head_node_time["occupied"]/(time() - head_node_time["start"])) * "%\n"
                # TODO - include command about "q" here.
                load_string *= @sprintf("Press 'q' and then <enter> to stop execution early.\n")
                equation_strings = load_string * equation_strings
                set_multiline_postfix(progress_bar, equation_strings)
                if cur_cycle === nothing
                    (cur_cycle, cur_state) = iterate(progress_bar)
                else
                    (cur_cycle, cur_state) = iterate(progress_bar, cur_state)
                end
                sum_cycle_remaining = sum(cycles_remaining)
            end
            head_node_end_work = time()
            head_node_time["occupied"] += (head_node_end_work - head_node_start_work)
        
            # Move moving window along frequencyComplexities:
            cur_size_frequency_complexities = sum(frequencyComplexities[j])
            if cur_size_frequency_complexities > window_size
                difference_in_size = cur_size_frequency_complexities - window_size
                frequencyComplexities[j] .-= difference_in_size / actualMaxsize
            end
        end
        sleep(1e-6)


        ################################################################
        ## Printing code
        elapsed = time() - last_print_time
        #Update if time has passed, and some new equations generated.
        if elapsed > print_every_n_seconds && num_equations > 0.0
            # Dominating pareto curve - must be better than all simpler equations
            current_speed = num_equations/elapsed
            average_over_m_measurements = 10 #for print_every...=5, this gives 50 second running average
            push!(equation_speed, current_speed)
            if length(equation_speed) > average_over_m_measurements
                deleteat!(equation_speed, 1)
            end
            if (options.verbosity > 0) || (options.progress && nout > 1)
                @printf("\n")
                average_speed = sum(equation_speed)/length(equation_speed)
                @printf("Cycles per second: %.3e\n", round(average_speed, sigdigits=3))
                @printf("Head worker occupation: %.1f%%\n", 100 * head_node_time["occupied"]/(time() - head_node_time["start"]))
                cycles_elapsed = total_cycles * nout - sum(cycles_remaining)
                @printf("Progress: %d / %d total iterations (%.3f%%)\n",
                        cycles_elapsed, total_cycles * nout,
                        100.0*cycles_elapsed/total_cycles/nout)

                @printf("==============================\n")
                for j=1:nout
                    if nout > 1
                        @printf("Best equations for output %d\n", j)
                    end
                    equation_strings = string_dominating_pareto_curve(hallOfFame[j], baselineMSEs[j],
                                                                      datasets[j], options,
                                                                      avgys[j])
                    print(equation_strings)
                    @printf("==============================\n")
                    
                    # Debugging code for frequencyComplexities:
                    # for size_i=1:actualMaxsize
                    #     @printf("frequencyComplexities size %d = %.2f\n", size_i, frequencyComplexities[j][size_i])
                    # end
                end
                @printf("Press 'q' and then <enter> to stop execution early.\n")
            end
            last_print_time = time()
            num_equations = 0.0
        end
        ################################################################

        ################################################################
        ## Early stopping code
        if options.earlyStopCondition !== nothing
            # Check if all nout are below stopping condition.
            all_below = true
            for j=1:nout
                dominating = calculateParetoFrontier(datasets[j], hallOfFame[j], options)
                # Check if zero size:
                if length(dominating) == 0
                    all_below = false
                elseif !any([options.earlyStopCondition(member.loss, member.complexity) for member in dominating])
                    # None of the equations meet the stop condition.
                    all_below = false
                end

                if !all_below
                    break
                end
            end
            if all_below # Early stop!
                break
            end
        end
        ################################################################

        ################################################################
        ## Signal stopping code
        if can_read_input
            bytes = bytesavailable(stdin)
            if bytes > 0
                # Read:
                data = read(stdin, bytes)
                control_c = 0x03
                quit = 0x71
                if length(data) > 1 && (data[end] == control_c || data[end - 1] == quit)
                    break
                end
            end
        end
        ################################################################

        ################################################################
        ## Timeout stopping code
        if options.timeout_in_seconds !== nothing
            if time() - start_time > options.timeout_in_seconds
                break
            end
        end
        ################################################################
    end
    if can_read_input
        Base.stop_reading(stdin)
    end
    if we_created_procs
        rmprocs(procs)
    end
    # TODO - also stop threads here.

    ##########################################################################
    ### Distributed code^
    ##########################################################################

    @recorder begin
        open(options.recorder_file, "w") do io
            JSON3.write(io, record, allow_inf = true)
        end
    end

    if options.stateReturn
        state = (returnPops, (nout == 1 ? hallOfFame[1] : hallOfFame))
        state::StateType{T}
        return state
    else
        if nout == 1
            return hallOfFame[1]
        else
            return hallOfFame
        end
    end
end


end #module SR
