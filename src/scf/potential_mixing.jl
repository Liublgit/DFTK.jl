# Change by implementing a heuristics that does the extra EρV only when needed.
# Test it a bit
# Refactor the code to be more in line with SCF

function estimate_optimal_step_size(basis, δF, δV, ρout, ρ_spin_out, ρnext, ρ_spin_next)
    # δF = F(V_out) - F(V_in)
    # δV = V_next - V_in
    # δρ = ρ(V_next) - ρ(V_in)
    dVol = basis.model.unit_cell_volume / prod(basis.fft_size)
    n_spin = basis.model.n_spin_components

    δρ = (ρnext - ρout).real
    if !isnothing(ρ_spin_out)
        δρspin = (ρ_spin_next - ρ_spin_out).real
        δρ_RFA     = from_real(basis, δρ)
        δρspin_RFA = from_real(basis, δρspin)

        δρα = (δρ + δρspin) / 2
        δρβ = (δρ - δρspin) / 2
        δρ = cat(δρα, δρβ, dims=4)
    else
        δρ_RFA = from_real(basis, δρ)
        δρspin_RFA = nothing
        δρ = reshape(δρ, basis.fft_size..., 1)
    end

    slope = dVol * dot(δF, δρ)
    Kδρ = apply_kernel(basis, δρ_RFA, δρspin_RFA; ρ=ρout, ρspin=ρ_spin_out)
    if n_spin == 1
        Kδρ = reshape(Kδρ[1].real, basis.fft_size..., 1)
    else
        Kδρ = cat(Kδρ[1].real, Kδρ[2].real, dims=4)
    end

    curv = dVol*(-dot(δV, δρ) + dot(δρ, Kδρ))
    # curv = abs(curv)  # Not sure we should explicitly do this

    # E = slope * t + 1/2 curv * t^2
    αopt = -slope/curv

    αopt, slope, curv
end

function anderson()
    Vs = []
    δFs = []

    function get_next(basis, V, δF)
        model = basis.model
        n_spin = model.n_spin_components

        # generate new direction δV from history
        function weight(dV)  # Precondition with Kerker
            dVr = copy(reshape(dV, basis.fft_size..., n_spin))
            Gsq = [sum(abs2, model.recip_lattice * G) for G in G_vectors(basis)]
            w = (Gsq .+ 1) ./ (Gsq)
            w[1] = 1
            # for σ in 1:n_spin
            #     dVr[:, :, :, σ] = from_fourier(basis, w .* from_real(basis, dVr[:, :, :, σ]).fourier).real
            # end
            dV
        end
        δV = δF
        if !isempty(Vs)
            mat = hcat(δFs...) .- vec(δF)
            mat = mapslices(weight, mat; dims=[1])
            alphas = -mat \ weight(vec(δF))
            # alphas = -(mat'mat) * mat' * vec(δF)
            for iα = 1:length(Vs)
                δV += reshape(alphas[iα] * (Vs[iα] + δFs[iα] - vec(V) - vec(δF)), basis.fft_size..., n_spin)
            end
        end
        push!(Vs, vec(V))
        push!(δFs, vec(δF))

        δV
    end
end

@timing function potential_mixing(basis::PlaneWaveBasis;
                                  n_bands=default_n_bands(basis.model),
                                  ρ=guess_density(basis),
                                  ρspin=guess_spin_density(basis),
                                  ψ=nothing,
                                  tol=1e-6,
                                  maxiter=100,
                                  solver=scf_nlsolve_solver(),
                                  eigensolver=lobpcg_hyper,
                                  n_ep_extra=3,
                                  determine_diagtol=ScfDiagtol(),
                                  mixing=SimpleMixing(),
                                  is_converged=ScfConvergenceEnergy(tol),
                                  callback=ScfDefaultCallback(),
                                  compute_consistent_energies=true,
                                  )
    T = eltype(basis)
    model = basis.model

    # All these variables will get updated by fixpoint_map
    if ψ !== nothing
        @assert length(ψ) == length(basis.kpoints)
        for ik in 1:length(basis.kpoints)
            @assert size(ψ[ik], 2) == n_bands + n_ep_extra
        end
    end
    occupation = nothing
    eigenvalues = nothing
    εF = nothing
    n_iter = 0
    energies = nothing
    ham = nothing
    n_spin = basis.model.n_spin_components
    ρout = ρ
    ρ_spin_out = ρspin

    _, ham = energy_hamiltonian(ρ.basis, nothing, nothing; ρ=ρ, ρspin=ρspin)
    V = cat(total_local_potential(ham)..., dims=4)

    dVol = model.unit_cell_volume / prod(basis.fft_size)

    function EρV(V; diagtol=tol / 10)
        Vunpack = [@view V[:, :, :, σ] for σ in 1:n_spin]
        ham_V = hamiltonian_with_total_potential(ham, Vunpack)
        res_V = next_density(ham_V; n_bands=n_bands,
                             ψ=ψ, n_ep_extra=3, miniter=1, tol=diagtol)
        # println("    n_iter = ", mean(res_V.diagonalization.iterations))
        new_E, new_ham = energy_hamiltonian(basis, res_V.ψ, res_V.occupation;
                                            ρ=res_V.ρout, ρspin=res_V.ρ_spin_out,
                                            eigenvalues=res_V.eigenvalues, εF=res_V.εF)
        ψ = res_V.ψ
        # println(res_V.eigenvalues[1][5] - res_V.eigenvalues[1][4])
        new_E.total, res_V.ρout, res_V.ρ_spin_out, total_local_potential(new_ham)
    end

    optimal_damping = false  # always optimal damping?
    δF = nothing
    α  = nothing  # nothing means that optimal damping will be determined in the first step
    αmax = 2
    V_prev = V
    ρ_prev = ρ
    ρ_spin_prev = ρspin
    info = (ρin=ρ_prev, ρnext=ρ, n_iter=1)
    diagtol = determine_diagtol(info)

    get_next = anderson()
    Eprev = Inf
    for i = 1:maxiter
        # println("   diagtol = $diagtol")
        E, ρout, ρ_spin_out, Vout = EρV(V; diagtol=diagtol)
        Vout = cat(Vout..., dims=4)

        # Horrible mapping to the density-based SCF to use this function
        info = (ρin=ρ_prev, ρnext=ρout, n_iter=i + 1)
        diagtol = determine_diagtol(info)

        ΔE = E - Eprev
        abs(ΔE) < tol && break

        println("Step $i")
        println("    ΔE           = ", ΔE, "     E = ", E)
        if !isnothing(ρ_spin_out)
            println("    Magnet       = ", sum(ρ_spin_out.real) * dVol)
        end
        if i > 1
            # Use the δF and δV from the previous iteration
            # (i.e. the one which got us to V) to determine a damping for the next step.
            δV_prev = V - V_prev
            α, slope, curv = estimate_optimal_step_size(basis, δF, δV_prev,
                                                        ρ_prev, ρ_spin_prev,
                                                        ρout, ρ_spin_out)
            α = min(α, αmax)
            println("    rel curv     = ", curv / (dVol*dot(δV_prev, δV_prev)))

            # E(α) = slope * α + ½ curv * α²
            println("    predicted ΔE = ", slope + curv/2)
            println("    α            = ", α)
            println("    pred. damp ΔE= ", slope * α + curv * α^2 / 2)

            if ΔE > 0 && α > 0
                println("    Rejecting step")  # TODO Also reject the ψ we stored!
                println()
                V = V_prev + α * δV_prev
                continue  # Reject this step (but keep the update on α)
            end
        end

        # Update state
        Eprev = E
        ρ_prev = ρout
        ρ_spin_prev = ρ_spin_out
        V_prev = V
        δF = Vout - V_prev
        δV = get_next(basis, V_prev, δF)

        # Damped iteration / line search
        if optimal_damping || isnothing(α) || α ≤ 0
            println("    Solving for optimal damping")
            _, ρnext, ρ_spin_next, _ = EρV(V + δV, diagtol=diagtol)
            αopt, slope, curv = estimate_optimal_step_size(basis, δF, δV, ρout, ρ_spin_out,
                                                           ρnext, ρ_spin_next)
            println("    αopt         = ", αopt)
            println("    opt. damp ΔE = ", slope * αopt + curv * αopt^2 / 2)

            V = V + αopt * δV
        else
            V = V + α * δV
        end
        println()
    end

    Vunpack = [@view V[:, :, :, σ] for σ in 1:n_spin]
    ham = hamiltonian_with_total_potential(ham, Vunpack)
    info = (ham=ham, basis=basis, energies=energies, converged=converged,
            ρ=ρout, ρspin=ρ_spin_out, eigenvalues=eigenvalues, occupation=occupation, εF=εF,
            n_iter=n_iter, n_ep_extra=n_ep_extra, ψ=ψ)
    info
end
