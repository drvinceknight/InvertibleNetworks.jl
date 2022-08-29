# Take around 3 minutes on CPU
using InvertibleNetworks
using Flux
using LinearAlgebra
using MLDatasets
using Statistics
using PyPlot
using ProgressMeter: Progress, next!
using Images
using MLUtils

function posterior_sampler(G, y, size_x; num_samples=16)
	# make samples from posterior
    Y_repeat = repeat(y |> cpu, 1, 1, 1, num_samples) |> device
    ZX_noise = randn(Float32, size_x[1:(end-1)]..., num_samples) |> device;
    X_post = G.inverse(ZX_noise, Y_repeat);
end

# Training hyperparameters
device = cpu #GPU does not accelerate at this small size. quicker on cpu
lr     = 4f-3
epochs = 15
batch_size = 128

# Load in training data
n_total = 2048
validation_perc = 0.9
X, _ = MNIST(split=:train)[1:(n_total)];

# Resize spatial size to a power of two to make Real-NVP multiscale easier. 
nx = 16; ny = 16;
Xs = zeros(Float32, nx, ny, 1, n_total);
for i in 1:n_total
	Xs[:,:,:,i] = imresize(X[:,:,i]', (nx, ny));
end

# Make Forward operator A
mask_size = 3 #number of pixels to zero out
mask_start = div((nx-mask_size),2)
A  = ones(Float32,nx,ny)
A[mask_start:(end-mask_start),mask_start:(end-mask_start)] .= 0f0

# Make observations y 
Ys = A .* Xs;

# Use MLutils to split into training and validation set
XY_train, XY_val = splitobs((Xs, Ys); at=validation_perc, shuffle=true);
train_loader = DataLoader(XY_train, batchsize=batch_size, shuffle=true, partial=false);

# Number of training batches 
n_train = numobs(XY_train)
n_val = numobs(XY_val)
batches = cld(n_train, batch_size)
progress = Progress(epochs*batches);

# Architecture parametrs
chan_x = 1    # not RGB so chan=1
chan_y = 1    # not RGB so chan=1
L = 2         # Number of multiscale levels
K = 10        # Number of Real-NVP layers per multiscale level
n_hidden = 32 # Number of hidden channels in convolutional residual blocks

# Create network
G = NetworkConditionalGlow(chan_x, chan_y, n_hidden,  L, K;) |> device;

# Optimizer
opt = ADAM(lr)

# Training logs 
loss_train = [];
loss_val = [];

for e=1:epochs # epoch loop
    for (X, Y) in train_loader #batch loop
    	X |> device;
        Y |> device;

        ZX, logdet_i = G.forward(X, Y);

        G.backward(ZX / batch_size, ZX, Y)

        for p in get_params(G) 
        	Flux.update!(opt, p.data, p.grad)
        end
        clear_grad!(G) # clear gradients unless you need to accumulate

        #Progress meter
        N = prod(size(X)[1:end-1])
        append!(loss_train, norm(ZX)^2 / (N*batch_size) - logdet_i / N)  # normalize by image size and batch size
    	next!(progress; showvalues=[
    		(:objective, loss_train[end])])
    end

    # Evaluate network on validation set 
    X = getobs(XY_val[1]) |> device
    Y = getobs(XY_val[2]) |> device

    ZX, logdet_i = G.forward(X, Y); 

    N = prod(size(X)[1:end-1])
    append!(loss_val, norm(ZX)^2 / (N*n_val) - logdet_i / N)  # normalize by image size and batch size
end

# Make generative conditional samples
num_plot = 4
fig = figure(figsize=(13, 9));
for i in [1,3]
	x = XY_val[1][:,:,:,i:i] |> cpu;
	y = XY_val[2][:,:,:,i:i]
	X_post = posterior_sampler(G, y, size(x); num_samples=64) 

	X_post_mean = mean(X_post; dims=ndims(X_post)) |> cpu
	X_post_var  = var(X_post;  dims=ndims(X_post)) |> cpu

	ssim_val = round(assess_ssim(X_post_mean[:,:,1,1], x[:,:,1,1]) ,digits=2)

	subplot(num_plot,7,1+7*(i-1)); imshow(x[:,:,1,1],  cmap="gray")
	axis("off"); title(L"$x_{gt} \sim p(x,y)$");

	subplot(num_plot,7,2+7*(i-1)); imshow(y[:,:,1,1] |> cpu,  cmap="gray")
	axis("off"); title(L"$y \sim p(x,y)$"); 

	subplot(num_plot,7,3+7*(i-1)); imshow(X_post_mean[:,:,1,1] ,  cmap="gray")
	axis("off"); title("SSIM="*string(ssim_val)*" \n"*L"$\mathrm{E_x} \, p_{\theta}(x | y)$") ; 

	subplot(num_plot,7,4+7*(i-1)); imshow(X_post_var[:,:,1,1] ,  cmap="magma")
	axis("off"); title(L"$\mathrm{Var} \, p_{\theta}(x | y)$") ; 

	subplot(num_plot,7,5+7*(i-1)); imshow(X_post[:,:,1,1] |> cpu,  cmap="gray")
	axis("off"); title(L"$x\sim p_{\theta}(x | y)$") ; 

	subplot(num_plot,7,6+7*(i-1)); imshow(X_post[:,:,1,2] |> cpu, cmap="gray")
	axis("off"); title(L"$x\sim p_{\theta}(x | y)$") ; 

	subplot(num_plot,7,7+7*(i-1)); imshow(X_post[:,:,1,3] |> cpu, cmap="gray")
	axis("off"); title(L"$x\sim p_{\theta}(x | y)$") ; 
end
tight_layout()
savefig("mnist_sampling_cond.png",dpi=300)

# Training logs
final_obj_train = round(loss_train[end];digits=3)
final_obj_val = round(loss_val[end];digits=3)

fig = figure()
title("Objective value: train=$(final_obj_train) validation=$(final_obj_val)")
plot(loss_train;label="Train"); 
plot(batches:batches:batches*(epochs), loss_val;label="Validation"); 
xlabel("Parameter update"); ylabel("Negative log likelihood objective") ;
legend()


# Make Figure of README
num_plot = 2
fig = figure(figsize=(11, 5));
for (i,ind) in enumerate([1,3])
	x = XY_val[1][:,:,:,ind:ind] |> cpu;
	y = XY_val[2][:,:,:,ind:ind]
	X_post = posterior_sampler(G, y, size(x); num_samples=64) 

	X_post_mean = mean(X_post; dims=ndims(X_post)) |> cpu
	X_post_var  = var(X_post;  dims=ndims(X_post)) |> cpu

	ssim_val = round(assess_ssim(X_post_mean[:,:,1,1], x[:,:,1,1]) ,digits=2)

	subplot(num_plot,7,1+7*(i-1)); imshow(x[:,:,1,1],  vmin=0, vmax=1, cmap="gray")
	axis("off"); title(L"$x$");

	subplot(num_plot,7,2+7*(i-1)); imshow(y[:,:,1,1] |> cpu,  cmap="gray")
	axis("off"); title(L"$y$"); 

	subplot(num_plot,7,3+7*(i-1)); imshow(X_post_mean[:,:,1,1] ,  vmin=0, vmax=1, cmap="gray")
	axis("off"); title("SSIM="*string(ssim_val)*" \n"*"Conditional Mean") ; 

	subplot(num_plot,7,4+7*(i-1)); imshow(X_post_var[:,:,1,1] ,  cmap="magma")
	axis("off"); title(L"$UQ$") ; 

	subplot(num_plot,7,5+7*(i-1)); imshow(X_post[:,:,1,1] |> cpu,   vmin=0, vmax=1,cmap="gray")
	axis("off"); title("Posterior Sample") ; 

	subplot(num_plot,7,6+7*(i-1)); imshow(X_post[:,:,1,2] |> cpu,  vmin=0, vmax=1,cmap="gray")
	axis("off"); title("Posterior Sample") ; 

	subplot(num_plot,7,7+7*(i-1)); imshow(X_post[:,:,1,3] |> cpu, vmin=0, vmax=1, cmap="gray")
	axis("off"); title("Posterior Sample") ; 
end
tight_layout()
savefig("mnist_sampling_cond.png",dpi=300,bbox_inches="tight")

