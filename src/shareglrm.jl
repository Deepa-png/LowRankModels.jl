import Base: size, axpy!
import Base.LinAlg.scale!
import ArrayViews: view, StridedView, ContiguousView
import Base: shmem_rand, shmem_randn
export GLRM, objective, Params, getindex, display, size, fit, fit!

function localcols(Y::SharedArray)
    idxs=localindexes(Y)
    s,t=localindexes(Y)[1],localindexes(Y)[end]
    m,n=size(Y)
    return ((s-1)/m+1):(t/m)
end

type GLRM
    A
    observed_features
    observed_examples
    losses::Array{Loss,1}
    rx::Regularizer
    ry::Regularizer
    k::Int64
    X::AbstractArray # k x n
    Y::AbstractArray # k x m
end
# default initializations for obs, X, and Y
GLRM(A,observed_features,observed_examples,losses,rx,ry,k) = 
    GLRM(A,observed_features,observed_examples,losses,rx,ry,k,shmem_randn(k,size(A,1)),shmem_randn(k,size(A,2)))
GLRM(A,obs,losses,rx,ry,k,X,Y) = 
    GLRM(A,sort_observations(obs,size(A)...)...,losses,rx,ry,k,X,Y)
GLRM(A,obs,losses,rx,ry,k) = 
    GLRM(A,obs,losses,rx,ry,k,shmem_randn(k,size(A,1)),shmem_randn(k,size(A,2)))
GLRM(A,losses,rx,ry,k) = 
    GLRM(A,reshape((Int64,Int64)[(i,j) for i=1:size(A,1),j=1:size(A,2)], prod(size(A))),losses,rx,ry,k)    
function objective(glrm::GLRM,X,Y,Z=nothing; include_regularization=true)
    m,n = size(glrm.A)
    err = 0
    # compute value of loss function
    if Z==nothing Z = X'*Y end
    for i=1:m
        for j in glrm.observed_features[i]
            err += evaluate(glrm.losses[j], Z[i,j], glrm.A[i,j])
        end
    end
    # add regularization penalty
    if include_regularization
        for i=1:m
            err += evaluate(glrm.rx,view(X,i,:))
        end
        for j=1:n
            err += evaluate(glrm.ry,view(Y,:,j))
        end
    end
    return err
end
objective(glrm::GLRM) = objective(glrm,glrm.X,glrm.Y)

type Params
    stepsize # stepsize
    max_iter # maximum number of iterations
    convergence_tol # stop when decrease in objective per iteration is less than convergence_tol*length(obs)
    min_stepsize # use a decreasing stepsize, stop when reaches min_stepsize
end
Params(stepsize,max_iter,convergence_tol) = Params(stepsize,max_iter,convergence_tol,stepsize)
Params() = Params(1,100,.00001,.01)

function sort_observations(obs,m,n; check_empty=false)
    observed_features = Array{Int32,1}[Int32[] for i=1:m]
    observed_examples = Array{Int32,1}[Int32[] for j=1:n]
    for (i,j) in obs
        push!(observed_features[i],j)
        push!(observed_examples[j],i)
    end
    if check_empty && (any(map(x->length(x)==0,observed_examples)) || 
            any(map(x->length(x)==0,observed_features)))
        error("Every row and column must contain at least one observation")
    end
    return observed_features, observed_examples
end

function fit!(glrm::GLRM; params::Params=Params(),ch::ConvergenceHistory=ConvergenceHistory("glrm"),verbose=true)
	
	### initialization
    mA = convert(SharedArray,glrm.A)
	# at any time, glrm.X and glrm.Y will be the best model yet found, while
	# X and Y will be the working variables
    # check that we didn't initialize to zero (otherwise we will never move)
    if norm(glrm.Y) == 0 
        glrm.Y = .1*randn(size(glrm.Y)...) 
    end
	mX = convert(SharedArray,glrm.X); mY = convert(SharedArray,glrm.Y)
	k = glrm.k
    # step size (will be scaled below to ensure it never exceeds 1/\|g\|_2 or so for any subproblem)
    malpha = Base.shmem_fill(params.stepsize,(1,1))

    # send all the data
    @parallel for i in workers()
        global A=mA
        global AT=mAT
        global X=mX
        global Y=mY
        global losses=glrm.losses
        global rx=glrm.rx
        global ry=glrm.ry
        global of=glrm.observed_features
        global oe=glrm.observed_examples
        global alpha=malpha
    end

    # make data accessible from master as well
    A,X,Y,losses,rx,ry,of,oe,alpha = mA,mX,mY,glrm.losses,glrm.rx,glrm.ry,glrm.observed_features,glrm.observed_examples,malpha

    # stopping criterion: stop when decrease in objective < tol
    tol = params.convergence_tol * mapreduce(length,+,glrm.observed_features)

    # alternating updates of X and Y
    if verbose println("Fitting GLRM") end
    update!(ch, 0, objective(glrm))
    t = time()
    steps_in_a_row = 0
    g = zeros(k)

    # cache views
    @everywhere begin
        m,n = size(A)
        ve = ContiguousView{Float64,1,Array{Float64,2}}[view(X,:,e) for e=1:m]
        vf = ContiguousView{Float64,1,Array{Float64,2}}[view(Y,:,f) for f=1:n]
        g = zeros(k)
    end
    for i=1:params.max_iter
        # X update
        @everywhere begin
            lcols = localcols(X)
            XY = X[:,lcols]'*Y
            for e=lcols
                # a gradient of L wrt e
                scale!(g, 0)
                for f in of[e]
                	axpy!(grad(losses[f],XY[e-lcols[1]+1,f],A[e,f]), vf[f], g)
                end
                # take a proximal gradient step
                ## gradient step: g = X[e,:] - alpha/l*g
                l = length(of[e]) + 1
                scale!(g, -alpha[1]/l)
                axpy!(1,g,ve[e])
                ## prox step: X[e,:] = prox(g)
                prox!(rx,ve[e],alpha[1]/l)
            end
        end
        # Y update
        @everywhere begin
            lcols = localcols(Y)
            XY = X'*Y[:,lcols]
            for f=lcols
                # a gradient of L wrt e
                scale!(g, 0)
                for f in of[e]
                    axpy!(grad(losses[f],XY[e,f-lcols[1]+1],A[e,f]), vf[f], g)
                end
                # take a proximal gradient step
                ## gradient step: g = X[e,:] - alpha/l*g
                l = length(oe[f]) + 1
                scale!(g, -alpha[1]/l)
                axpy!(1,g,vf[f])
                ## prox step: X[e,:] = prox(g)
                prox!(ry,vf[f],alpha[1]/l)
            end
        end
        obj = objective(glrm,X,Y)
        # record the best X and Y yet found
        if obj < ch.objective[end]
            t = time() - t
            update!(ch, t, obj)
            copy!(glrm.X, X); copy!(glrm.Y, Y)
            alpha = alpha * 1.05
            steps_in_a_row = max(1, steps_in_a_row+1)
            t = time()
        else
            # if the objective went up, reduce the step size, and undo the step
            alpha = alpha / max(1.5, -steps_in_a_row)
            copy!(X, glrm.X); copy!(Y, glrm.Y)
            steps_in_a_row = min(0, steps_in_a_row-1)
        end
        # check stopping criterion
        if i>10 && (steps_in_a_row > 3 && ch.objective[end-1] - obj < tol) || alpha <= params.min_stepsize
            break
        end
        if verbose && i%10==0 
            println("Iteration $i: objective value = $(ch.objective[end])") 
        end
    end
    t = time() - t
    update!(ch, t, ch.objective[end])

    return glrm.X,glrm.Y,ch
end

function fit(glrm::GLRM, args...; kwargs...)
    X0 = Array(Float64, size(glrm.X))
    Y0 = Array(Float64, size(glrm.Y))
    copy!(X0, glrm.X); copy!(Y0, glrm.Y)
    X,Y,ch = fit!(glrm, args...; kwargs...)
    copy!(glrm.X, X0); copy!(glrm.Y, Y0)
    return X,Y,ch
end