using Test
using DFTK

include("determine_grid_size.jl")
include("fourier_transforms.jl")
include("PlaneWaveModel.jl")
include("PspHgh.jl")
include("Species.jl")
include("bzmesh.jl")

include("term_external.jl")
# include("term_nonlocal.jl")  TODO does not work yet
# TODO Test for term_hartree
# TODO Test for term_xc

include("lobpcg.jl")
include("xc_fallback.jl")

include("energy_ewald.jl")
include("energy_nuclear.jl")
include("occupation.jl")
# include("energies_guess_density.jl")
include("compute_density.jl")

include("scf_compare.jl")
include("silicon_redHF.jl")
include("silicon_lda.jl")
include("silicon_pbe.jl")
