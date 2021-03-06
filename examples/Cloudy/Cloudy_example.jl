# This example requires Cloudy to be installed.
using Pkg; Pkg.add(PackageSpec(name="Cloudy", version="0.1.0"))
using Cloudy
const PDistributions = Cloudy.ParticleDistributions

# Import modules
using Distributions  # probability distributions and associated functions
using StatsBase
using LinearAlgebra
using StatsPlots
using GaussianProcesses
using Plots
using Random

# Import Calibrate-Emulate-Sample modules
using CalibrateEmulateSample.EKP
using CalibrateEmulateSample.GPEmulator
using CalibrateEmulateSample.MCMC
using CalibrateEmulateSample.Observations
using CalibrateEmulateSample.Utilities
using CalibrateEmulateSample.ParameterDistributionStorage

# Import the module that runs Cloudy
include("GModel.jl")
using .GModel

################################################################################
#                                                                              #
#                      Cloudy Calibrate-Emulate-Sample Example                 #
#                                                                              #
#                                                                              #
#     This example uses Cloudy, a microphysics model that simulates the        #
#     coalescence of cloud droplets into bigger drops, to demonstrate how      #
#     the full Calibrate-Emulate-Sample pipeline can be used for Bayesian      #
#     learning and uncertainty quantification of parameters, given some        #
#     observations.                                                            #
#                                                                              #
#     Specifically, this examples shows how to learn parameters of the         #
#     initial cloud droplet mass distribution, given observations of some      #
#     moments of that mass distribution at a later time, after some of the     #
#     droplets have collided and become bigger drops.                          #
#                                                                              #
#     In this example, Cloudy is used in a "perfect model" (aka "known         #
#     truth") setting, which means that the "observations" are generated by    #
#     Cloudy itself, by running it with the true parameter values. In more     #
#     realistic applications, the observations will come from some external    #
#     measurement system.                                                      #
#                                                                              #
#     The purpose is to show how to do parameter learning using                #
#     Calibrate-Emulate-Sample in a simple (and highly artificial) setting.    #
#                                                                              #
#     For more information on Cloudy, see                                      #
#              https://github.com/CliMA/Cloudy.jl.git                          #
#                                                                              #
################################################################################


rng_seed = 41
Random.seed!(rng_seed)

###
###  Define the (true) parameters and their priors
###

# Define the parameters that we want to learn
# We assume that the true particle mass distribution is a Gamma distribution 
# with parameters N0_true, θ_true, k_true
param_names = ["N0", "θ", "k"]
n_param = length(param_names)

N0_true = 300.0  # number of particles (scaling factor for Gamma distribution)
θ_true = 1.5597  # scale parameter of Gamma distribution
k_true = 0.0817  # shape parameter of Gamma distribution
params_true = [N0_true, θ_true, k_true]
# Note that dist_true is a Cloudy distribution, not a Distributions.jl 
# distribution
dist_true = PDistributions.Gamma(N0_true, θ_true, k_true)


###
###  Define priors for the parameters we want to learn
###

# Define constraints
lbound_N0 = 0.4 * N0_true 
lbound_θ = 1.0e-1
lbound_k = 1.0e-4
c1 = bounded_below(lbound_N0)
c2 = bounded_below(lbound_θ)
c3 = bounded_below(lbound_k)
constraints = [[c1], [c2], [c3]]

# We choose to use normal distributions to represent the prior distributions of
# the parameters in the transformed (unconstrained) space.
d1 = Parameterized(Normal(0.0, 1.0))
d2 = Parameterized(Normal(0.0, 1.0))
d3 = Parameterized(Normal(0.0, 1.0))
distributions = [d1, d2, d3]

param_names = ["N0", "θ", "k"]

priors = ParameterDistribution(distributions, constraints, param_names)

###
###  Define the data from which we want to learn the parameters
###

data_names = ["M0", "M1", "M2"]
moments = [0.0, 1.0, 2.0]
n_moments = length(moments)


###
###  Model settings
###

# Collision-coalescence kernel to be used in Cloudy
coalescence_coeff = 1/3.14/4/100
kernel_func = x -> coalescence_coeff
kernel = Cloudy.KernelTensors.CoalescenceTensor(kernel_func, 0, 100.0)

# Time period over which to run Cloudy
tspan = (0., 1.0)  


###
###  Generate (artificial) truth samples
###  Note: The observables y are related to the parameters θ by:
###        y = G(x1, x2) + η
###

g_settings_true = GModel.GSettings(kernel, dist_true, moments, tspan)
gt = GModel.run_G(params_true, g_settings_true, PDistributions.update_params, 
                  PDistributions.moment, Cloudy.Sources.get_int_coalescence)
n_samples = 100
yt = zeros(n_samples, length(gt))
# In a perfect model setting, the "observational noise" represent the internal
# model variability. Since Cloudy is a purely deterministic model, there is no
# straightforward way of coming up with a covariance structure for this internal
# model variability. We decide to use a diagonal covariance, with entries
# (variances) largely proportional to their corresponding data values, gt.
Γy = convert(Array, Diagonal([13.0, 1.2, 2.7]))
μ = zeros(length(gt))

# Add noise
for i in 1:n_samples
    yt[i, :] = gt .+ rand(MvNormal(μ, Γy))
end

truth = Observations.Obs(yt, Γy, data_names)


###
###  Calibrate: Ensemble Kalman Inversion
###

N_ens = 50 # number of ensemble members
N_iter = 5 # number of EKI iterations
# initial parameters: N_ens x N_params
initial_params = EKP.construct_initial_ensemble(priors, N_ens; rng_seed=6)
ekiobj = EKP.EKObj(initial_params, truth.mean, truth.obs_noise_cov,
                   Inversion(), Δt=0.3)

# Initialize a ParticleDistribution with dummy parameters. The parameters 
# will then be set in run_G_ensemble
dummy = 1.0
dist_type = PDistributions.Gamma(dummy, dummy, dummy)
g_settings = GModel.GSettings(kernel, dist_type, moments, tspan)

# EKI iterations
for i in 1:N_iter
    params_i = mapslices(x -> transform_unconstrained_to_constrained(priors, x),
                         ekiobj.u[end]; dims=2)
    g_ens = GModel.run_G_ensemble(params_i, g_settings,
                                  PDistributions.update_params,
                                  PDistributions.moment,
                                  Cloudy.Sources.get_int_coalescence)
    EKP.update_ensemble!(ekiobj, g_ens) 
end

# EKI results: Has the ensemble collapsed toward the truth?
transformed_params_true = transform_constrained_to_unconstrained(priors,
                                                                 params_true)
println("True parameters (transformed): ")
println(transformed_params_true)

println("\nEKI results:")
println(mean(ekiobj.u[end], dims=1))


###
###  Emulate: Gaussian Process Regression
###

gppackage = GPEmulator.GPJL()
pred_type = GPEmulator.YType()

# Construct kernel:
# Sum kernel consisting of Matern 5/2 ARD kernel, a Squared Exponential Iso 
# kernel and white noise. Note that the kernels take the signal standard 
# deviations on a log scale as input.
len1 = 1.0
kern1 = SE(len1, 1.0)
len2 = zeros(3)
kern2 = Mat52Ard(len2, 0.0)
white = Noise(log(2.0))
GPkernel =  kern1 + kern2 + white
# Get training points
u_tp, g_tp = Utilities.extract_GP_tp(ekiobj, N_iter)
normalized = true
gpobj = GPEmulator.GPObj(u_tp, g_tp, gppackage; GPkernel=GPkernel, 
                         obs_noise_cov=Γy, normalized=normalized, 
                         noise_learn=false, prediction_type=pred_type)

# Check how well the Gaussian Process regression predicts on the
# true parameters
y_mean, y_var = GPEmulator.predict(gpobj,
                                   reshape(transformed_params_true, 1, :),
                                   transform_to_real=true)

println("GP prediction on true parameters: ")
println(vec(y_mean))
println("true data: ")
println(truth.mean)


###
###  Sample: Markov Chain Monte Carlo
###

# initial values
u0 = vec(mean(u_tp, dims=1))
println("initial parameters: ", u0)

# MCMC settings
mcmc_alg = "rwm" # random walk Metropolis

# First let's run a short chain to determine a good step size
burnin = 0
step = 0.1 # first guess
max_iter = 5000
yt_sample = truth.mean
mcmc_test = MCMC.MCMCObj(yt_sample, Γy, priors, step, u0, max_iter, 
                         mcmc_alg, burnin, svdflag=true)
new_step = MCMC.find_mcmc_step!(mcmc_test, gpobj)

# Now begin the actual MCMC
println("Begin MCMC - with step size ", new_step)
u0 = vec(mean(u_tp, dims=1))
burnin = 1000
max_iter = 100000
mcmc = MCMC.MCMCObj(yt_sample, Γy, priors, new_step, u0, max_iter, mcmc_alg,
                    burnin, svdflag=true)
MCMC.sample_posterior!(mcmc, gpobj, max_iter)

posterior = MCMC.get_posterior(mcmc)

post_mean = get_mean(posterior)
post_cov = get_cov(posterior)
println("posterior mean")
println(post_mean)
println("posterior covariance")
println(post_cov)

# Plot the posteriors together with the priors and the true parameter values
# (in the transformed/unconstrained space)
n_params = length(get_name(posterior))

for idx in 1:n_params
    if idx == 1
        xs = collect(range(5.0, stop=5.5, length=1000))
    elseif idx == 2
        xs = collect(range(-1.0, stop=1.0, length=1000))
    elseif idx == 3
        xs = collect(range(-3.0, stop=-1.0, length=1000))
    else
        throw("not implemented")
    end

    label = "true " * param_names[idx]
    posterior_samples = dropdims(get_distribution(posterior)[param_names[idx]],
                                 dims=1)
    histogram(posterior_samples, bins=100, normed=true, fill=:slategray,
              thickness_scaling=2.0, lab="posterior", legend=:outertopright)
    prior_dist = get_distribution(mcmc.prior)[param_names[idx]]
    plot!(xs, prior_dist, w=2.6, color=:blue, lab="prior")
    plot!([transformed_params_true[idx]], seriestype="vline", w=2.6, lab=label)
    title!(param_names[idx])
    StatsPlots.savefig("posterior_" * param_names[idx] * ".png")
end
