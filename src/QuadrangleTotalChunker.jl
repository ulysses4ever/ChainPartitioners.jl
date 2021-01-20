struct ConvexTotalChunker{F}
    f::F
end

#TODO add reference partitioners to test optimized constrained dynamic ones.
#TODO add optimized constrained dynamic partitioner before optimized convex one.

function pack_stripe(A::SparseMatrixCSC{Tv, Ti}, method::ConvexTotalChunker, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(method.f, A, args...)

        ftr = CircularDeque{Tuple{Ti, Ti}}(n + 1)
        spl = zeros(Ti, n + 1)
        cst = fill(typemax(cost_type(f)), n + 1)
        cst[1] = zero(cost_type(f))
        f′(j, j′) = cst[j] + f(j, j′)
        chunk_convex!(cst, spl, f′, 1, n + 1, ftr)

        return unravel_chunks!(spl, n)
    end
end

function partition_stripe(A::SparseMatrixCSC{Tv, Ti}, K, method::ConvexTotalChunker, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(method.f, A, args...)

        if K == 1
            return SplitPartition{Ti}(1, [Ti(1), Ti(n + 1)])
        end

        ftr = Stack{Tuple{Ti, Ti}}(n + 1)

        ptr = zeros(Ti, n + 1, K)
        cst = fill(typemax(cost_type(f)), n + 1, K)

        for j′ = 1:n + 1
            cst[j′, 1] = f(1, j′, 1)
            ptr[j′, 1] = 1
        end
        for k = 2:K
            f′(j, j′) = cst[j, k - 1] + f(j, j′, k)
            for j′ = 1:n + 1
                cst[j′, k] = f′(j′, j′)
                ptr[j′, k] = j′ 
            end
            chunk_convex!((@view cst[:, k]), (@view ptr[:, k]), f′, 1, n + 1, ftr)
        end
        return unravel_splits(K, n, PermutedDimsArray(ptr, (2, 1)))
    end
end

function chunk_convex!(cst, ptr, f, j₀, j′₁, ftr)
    empty!(ftr)
    push!(ftr, (j₀, j′₁))
    for j′ = j₀ + 1:j′₁
        (j, h) = first(ftr)
        if f(j′ - 1, j′) ≥ f(j, j′)
            if f(j, j′) <= cst[j′]
                cst[j′] = f(j, j′)
                ptr[j′] = j
            end
            if h == j′
                pop!(ftr)
            end
        else
            if f(j′ - 1, j′) <= cst[j′]
                cst[j′] = f(j′ - 1, j′)
                ptr[j′] = j′ - 1
            end
            while !isempty(ftr) && ((j, h) = first(ftr); (f(j′ - 1, h) < f(j, h)))
                pop!(ftr)
            end
            if isempty(ftr)
                push!(ftr, (j′ - 1, j′₁))
            else
                (j, h) = first(ftr)
                h_lo = j′
                h_hi = h
                #=
                h_ref = h_lo
                while h_ref < h_hi && f(j′ - 1, h_ref + 1) < f(j, h_ref + 1)
                    h_ref += 1
                end
                =#
                while h_lo <= h_hi
                    h = fld2(h_lo + h_hi)
                    if f(j′ - 1, h) < f(j, h)
                        h_lo = h + 1
                    else
                        h_hi = h - 1
                    end
                end
                h = h_hi

                if j′ < h
                    push!(ftr, (j′ - 1, h))
                end
            end
        end
    end
end

function pack_stripe(A::SparseMatrixCSC{Tv, Ti}, method::ConvexTotalChunker{<:ConstrainedCost}, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(method.f.f, A, args...)
        w = oracle_stripe(method.f.w, A, args...)
        w_max = method.f.w_max

        ftr = CircularDeque{Tuple{Ti, Ti}}(2n + 1)
        σ_j = undefs(Ti, 2n + 1)
        σ_j′ = undefs(Ti, 2n + 1)
        σ_ptr = undefs(Ti, 2n + 1)
        σ_cst = undefs(cost_type(f), 2n + 1)

        spl = zeros(Ti, n + 1)
        cst = fill(typemax(cost_type(f)), n + 1)
        cst[1] = zero(cost_type(f))
        f′(j, j′) = cst[j] + f(j, j′)
        chunk_convex_constrained!(cst, spl, f′, w, w_max, 1, n + 1, ftr, σ_j, σ_j′, σ_cst, σ_ptr)

        return unravel_chunks!(spl, n)
    end
end

#=
function partition_stripe(A::SparseMatrixCSC{Tv, Ti}, K, method::ConvexTotalChunker{<:ConstrainedCost}, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(method.f, A, args...)
        w = f.w
        w_max = method.f.w_max

        if K == 1
            return SplitPartition{Ti}(1, [Ti(1), Ti(n + 1)])
        end

        ptr = zeros(Ti, n + 1, K)
        cst = fill(typemax(cost_type(f)), n + 1, K)

        ftr = Stack{Tuple{Ti, Ti}}(2n + 1)
        σ_j = undefs(Ti, 2n + 1)
        σ_j′ = undefs(Ti, 2n + 1)
        σ_ptr = undefs(Ti, 2n + 1)
        σ_cst = undefs(cost_type(method.f), 2n + 1)
    
        j_lo = undefs(Ti, K + 1)
        j′ = n + 1
        j_lo[K + 1] = n + 1
        for k = K:-1:1
            j = j′
            while j - 1 >= 1 && w(j - 1, j′, k) <= w_max
                j -= 1
            end
            j_lo[k] = j
            j′ = j
        end

        j′_hi = undefs(Ti, K)
        j = 1
        for k = 1:K
            j′ = j
            while j′ + 1 <= n + 1 && w(j, j′ + 1, k) <= w_max
                j′ += 1
            end
            j′_hi[k] = j′
            j = j′
        end

        if j′_hi[K] < n + 1
            spl = ones(Ti, K + 1)
            spl[end] = n + 1
            #TODO throw(ArgumentError("infeasible"))
            return SplitPartition(K, spl)
        end

        pos = undefs(Ti, K + 1)
        pos[1] = 1
        for k = 1:K
            pos[k + 1] = pos[k] + (1 + j′_hi[k] - j_lo[k])
        end

        ptr = zeros(Ti, pos[end])
        cst = undefs(cost_type(f), pos[end])

        for j′ = j_lo[2] : j′_hi[1]
            i′ = j′ - j_lo[1]
            cst[pos[1] + i′] = +(zero(cost_type(f)), f(1, j′, 1))
            ptr[pos[1] + i′] = 1
        end

        for k = 2:K
            for j′ = j_lo[k + 1] : j′_hi[k]
                function f′(i, i′)
                    j = j_lo[k] + i - 1
                    j′ = j_lo[k] + i′ - 1
                    if j > j′_hi[k - 1]
                        infinity(cost_type(f))
                    else
                        cst[pos[k - 1] + j - j_lo[k - 1] - 1] + f(j, j′, k)
                    end
                end
                #for j′ = j_lo[k + 1] : j′_hi[k]
                for j′ = j_lo[k] : j′_hi[k - 1]
                    i′ = j′ - j_lo[k] + 1
                    cst[pos[k] + i′ - 1] = f′(i′, i′) 
                    ptr[pos[k] + i′ - 1] = i′
                end
                chunk_convex_constrained!((@view cst[pos[k]:pos[k + 1] - 1]), (@view ptr[pos[k]:pos[k + 1] - 1]), f′, w, w_max, 1, j′_hi[k] - j_lo[k] + 1, ftr, σ_j, σ_j′, σ_cst, σ_ptr)
            end
        end

        for k = 1:K
            @info ptr[pos[k]:pos[k + 1] - 1]
        end
        println(ptr)

        spl = zeros(eltype(ptr), K + 1)
        spl[end] = n + 1
        for k = K:-1:1
            spl[k] = j_lo[k] + ptr[pos[k] + spl[k + 1] - j_lo[k]] - 1
        end

        return SplitPartition(K, spl)
    end
end
=#

function chunk_convex_constrained!(cst, ptr, f, w, w_max, J₀, J′₁, ftr, σ_j, σ_j′, σ_cst, σ_ptr)
    j′₁ = J₀ + 1
    while j′₁ < J′₁ && w(J₀, j′₁ + 1) <= w_max
        j′₁ += 1
    end
    j₀ = J₀

    while j′₁ <= J′₁
        chunk_convex!(cst, ptr, f, j₀, j′₁, ftr)

        if j′₁  == J′₁
            break
        end
        j′ = j′₁
        I = 1
        for j = j₀ + 1 : j′₁ # j = j₀ is redundant, as is j′ = j′₁.
            if j′ > j′₁
                σ_j′[I] = j′
                I += 1
                σ_j[I] = j
            end
            while j′ < J′₁ && w(j, j′ + 1) <= w_max
                j′ += 1
                #if j′ > j′₁
                    σ_j′[I] = j′
                    I += 1
                    σ_j[I] = j
                #end
            end
        end

        for i = 2:I-1
            σ_cst[i] = typemax(eltype(cst))
        end
        #have i < i′
        #need if j = σ_j[I], then j′ < σ_j′[I] (can do this with i < i′)
        #also need j < j′ but this is satisfied for any i, i′ since rand(σ_j) < rand(σ_j′)

        σ_f(i, i′) = f(σ_j[I - i], σ_j′[I - i′])
        chunk_convex!(σ_cst, σ_ptr, σ_f, 1, I - 1, ftr)

        for i′ = 2:I - 1
            cst[σ_j′[I - i′]] = σ_cst[i′]
            ptr[σ_j′[I - i′]] = σ_j[I - σ_ptr[i′]]
        end

        j₀ = j′₁
        j′₁ = σ_j′[I - 1]
    end
end