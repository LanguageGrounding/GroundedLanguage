using ArgParse
using JLD
using CUDArt
device(0)
using Knet: stack_isempty
using Knet
using DataFrames
using Base.LinAlg: axpy!, scale!


@knet function generic_layer(x; f1=:dot, f2=:relu, wdims=(), bdims=(), winit=Xavier(), binit=Constant(0))
	w = par(init=winit, dims=wdims)
	y = f1(w,x)
	b = par(init=binit, dims=bdims)
	z = add(b,y)
	return f2(z)
end

@knet function relu_layer(x; input=0, output=0)
	return generic_layer(x; f1=:dot, f2=:relu, wdims=(output,input), bdims=(output,1))
end

@knet function softmax_layer(x; input=0, output=0)
	return generic_layer(x; f1=:dot, f2=:soft, wdims=(output,input), bdims=(output,1))
end

function get_worldf(predtype, o)
	if predtype == "id" || predtype == "grid"
		@knet function output_layer(x; output=20)
			return wbf(x; out=output, f=:soft)
		end
	else
		@knet function output_layer(x; output=3)
			return wb(x; out=output)
		end
	end

	@knet function fnn(w, x; hidden=400, output=20, winit=Gaussian(0,0.05))
		h = wbf2(w, x; out=hidden, f=:relu, winit=winit)
		return wbf(h; out=output, f=:soft, winit=winit)
	end

	@knet function droprelu(x; hidden=100, pdrop=0.5)
		d = drop(x, pdrop=pdrop)
		return relu_layer(d; output=hidden)
	end

	@knet function fnn2(w, x; hidden=400, pdrop=0.5, output=20, nlayers=2)
		h = wbf2(w, x; out=hidden, f=:relu, winit=Gaussian(0,0.05))
		hl = repeat(h; frepeat=:droprelu, nrepeat=nlayers-1, hidden=hidden, pdrop=pdrop)
		return output_layer(hl; output=output)
	end
	
	outdim = predtype == "id" ? 20 : 18*18
	outdim = predtype == "loc" ? 3 : outdim
	worldf = nothing
	if o[:dropout] == 0
		worldf = compile(:fnn; hidden=o[:hidden], output=outdim)
	else
		worldf = compile(:fnn2; hidden=o[:hidden], pdrop=o[:dropout], output=outdim, nlayers=o[:nlayers])
	end
	return worldf
end

function pretraining(f; N=2^14, dims=(16, 1, 16), nblocks=20, lr=0.001, adam=true, nbatch=128, winit=Gaussian(0,0.05)) # 0.76@8192
	sloss = zloss = 0
	nextn = 1
	ncells = prod(dims)
	global world = zeros(Float32, length(dims), nblocks)
	global target = zeros(Float32, length(dims), 1)
	global ygold = zeros(Float32, nblocks,1)
	global world2 = zeros(Float32, length(dims)*nblocks, nbatch)
	global target2 = zeros(Float32, length(dims), nbatch)
	global ygold2 = zeros(Float32, nblocks,nbatch)

	for n=1:N
		for m=1:nbatch
			locations = randperm(ncells)
			for b=1:nblocks
				world[:,b] = 2*([ind2sub(dims, locations[b])...] / 16 - 0.5) # fill blocks with random locations
			end
			target[:,1] = 2*([ind2sub(dims, locations[nblocks+1])...] / 16 - 0.5) # pick target at an empty location
			d1 = world .- target
			d2 = sum(d1 .* d1, 1)
			d3 = rand(find(d2 .== minimum(d2))) # pick one of the closest blocks randomly
			ygold[:] = 0; ygold[d3] = 1
			world2[:,m] = vec(world) # fill the minibatch matrices
			target2[:,m] = target
			ygold2[:,m] = ygold
		end

		global ypred = forw(f, world2, target2)
		
		sl = softloss(ypred,ygold2); sloss = (n==1 ? sl : 0.99 * sloss + 0.01 * sl)
		zl = zeroone(ypred,ygold2);  zloss = (n==1 ? zl : 0.99 * zloss + 0.01 * zl)
		n==nextn && (println((n,sloss,1-zloss)); nextn*=2)
		back(f, ygold2, softloss)
		update!(f)
		reset!(f)
	end
end

function train(worldf, worlddata, loss; gclip=0, dropout=false)
	sumloss = numloss = 0
	reset!(worldf)
	wybatches = worlddata[1]
	wposbatches = worlddata[2]

	for i=1:length(wybatches)
		x,y = wybatches[i]
		_,pos = wposbatches[i]

		if dropout
			ypred = forw(worldf, x, pos, dropout=true)
		else
			ypred = forw(worldf, x, pos)
		end

		sumloss += size(y, 1) == 3 ? quadloss(ypred, y)*size(y,2) : zeroone(ypred, y)*size(y,2)
		numloss += size(y,2)

		back(worldf, y, loss)

		update!(worldf; gclip=gclip)
		reset!(worldf)
	end
	sumloss / numloss
end

function test(worldf, worlddata, loss, loc=false)
	sumloss = numloss = 0
	reset!(worldf)
	
	wybatches = worlddata[1]
	wposbatches = worlddata[2]

	for i=1:length(wybatches)
		x,y = wybatches[i]
		_,pos = wposbatches[i]
		ypred = forw(worldf, x, pos)
		sumloss += loss(ypred, y)*size(y,2)
		numloss += size(y,2)
		reset!(worldf)
	end
	sumloss / numloss
end

flat(A) = mapreduce(x->isa(x,Array)? flat(x): x, vcat, [], A)

function predict(worldf, worlddata; ftype=Float32, xsparse=false)
	reset!(worldf)
	ypreds = Any[]
	for (x,y) in worlddata
		ypred = forw(worldf, x)
		push!(ypreds, ypred)
	end
	println(flat(ypred))
end

#predtype = id | grid | loc
function get_worlds(rawdata; batchsize=100, predtype = "id", ftype=Float32, target=2)
	worlds = zeros(ftype, 60, size(rawdata, 1))

	ydim = 0
	if predtype == "id"
		ydim = 20
	elseif predtype == "loc"
		ydim = 3
	else
		ydim = 18 * 18
	end
	y = zeros(ftype, ydim, size(rawdata, 1))
	targpos = zeros(ftype, 3, size(rawdata, 1))

	println("Number of instances: $(size(rawdata, 1))")
	
	for indx=1:size(rawdata, 1)
		data = rawdata[indx, :]

		worlds[:, indx] = data[1, 1:60]'
		targpos[:, indx] = data[1, 225:227]'
		
		if predtype == "id"
			source = round(Int, data[1, 222+target-1])
			y[source, indx] = 1
		elseif predtype == "loc"
			source = round(Int, data[1, 222])
			y[:, indx] = data[1, (source*3 - 2):(source*3)]
		else
			source = round(Int, data[1, 222])
			x = round(Int, data[1, (source*3 - 2)] / 0.1524) + 10
			z = round(Int, data[1, (source*3)] / 0.1524) + 10
			source = (z-1)*18 + x
			y[source, indx] = 1
		end
		
	end
	return (minibatch(worlds, y, batchsize), minibatch(worlds, targpos, batchsize))
end

#julia loc2T.jl --lr 0.001 --epoch 100 --target 2 --hidden 400 --pretrain
#dev best: 0.192881
#nopretrain: 0.749399
#nopretrain drop 0.2: 0.726792
#nopretrain drop 0.3: 0.72583
function main(args)
	s = ArgParseSettings()
	s.exc_handler=ArgParse.debug_handler
	@add_arg_table s begin
		("--worlddatafiles"; nargs='+'; default=["../../BlockWorld/SimpleCombined/Train.WWT-STRPLocGrid.data", "../../BlockWorld/SimpleCombined/Dev.WWT-STRPLocGrid.data"])
		("--loadfile"; help="initialize model from file")
		("--savefile"; help="save final model to file")
		("--bestfile"; help="save best model to file")
		("--hidden"; arg_type=Int; default=100; help="hidden layer size")
		("--chidden"; arg_type=Int; default=0; help="hidden layer size")
		("--cwin"; arg_type=Int; default=2; help="filter size")
		("--cout"; arg_type=Int; default=20; help="number of filters")
		("--epochs"; arg_type=Int; default=10; help="number of epochs to train")
		("--batchsize"; arg_type=Int; default=10; help="minibatch size")
		("--lr"; arg_type=Float64; default=1.0; help="learning rate")
		("--gclip"; arg_type=Float64; default=5.0; help="gradient clipping threshold")
		("--dropout"; arg_type=Float64; default=0.0; help="dropout probability")
		("--fdropout"; arg_type=Float64; default=0.5; help="dropout probability for the first one")
		("--ldropout"; arg_type=Float64; default=0.5; help="dropout probability for the last one")
		("--decay"; arg_type=Float64; default=0.9; help="learning rate decay if deverr increases")
		("--nogpu"; action = :store_true; help="do not use gpu, which is used by default if available")
		("--loc"; action = :store_true; help="predict location")
		("--seed"; arg_type=Int; default=42; help="random number seed")
		("--nx"; arg_type=Int; default=101; help="number of input columns in data")
		("--ny"; arg_type=Int; default=3; help="number of target columns in data")
		("--target"; arg_type=Int; default=1; help="which target to predict: 1:source,2:target,3:direction")
		("--xvocab"; arg_type=Int; default=622; help="vocab size for input columns (all columns assumed equal)")
		("--yvocab"; arg_type=Int; nargs='+'; default=[20,20,8]; help="vocab sizes for target columns (all columns assumed independent)")
		("--xsparse"; action = :store_true; help="use sparse inputs, dense arrays used by default")
		("--ftype"; default = "Float32"; help="floating point type to use: Float32 or Float64")
		("--patience"; arg_type=Int; default=0; help="patience")
		("--nlayers"; arg_type=Int; default=2; help="number of layers")
		("--logfile"; help="csv file for log")
		("--predict"; action = :store_true; help="load net and give predictions")
		("--pretrain"; action = :store_true; help="pretraining")
		("--predtype"; default = "id"; help="prediction type: id, loc, grid")
	end

	isa(args, AbstractString) && (args=split(args))
	o = parse_args(args, s; as_symbols=true); println(o)
	o[:seed] > 0 && setseed(o[:seed])
	o[:ftype] = eval(parse(o[:ftype]))

	#global rawdata = map(f->readdlm(f,Int), o[:datafiles])

	# Minibatch data: data[1]:train, data[2]:dev
	xrange = 1:o[:nx]
	yrange = (o[:nx] + o[:target]):(o[:nx] + o[:target])
	yvocab = o[:yvocab][o[:target]]

	#===========
	global data = map(rawdata) do d
		minibatch(d, xrange, yrange, o[:batchsize]; xvocab=o[:xvocab], yvocab=yvocab, ftype=o[:ftype], xsparse=o[:xsparse])
	end
	==========#

	rawworlddata = map(f->readdlm(f,Float32), o[:worlddatafiles])

	global worlddata = map(rawworlddata) do d
		r = randperm(size(d,1))
		get_worlds(d[r,:], batchsize=o[:batchsize], predtype=o[:predtype], target=o[:target])
	end
	
	worldf = get_worldf(o[:predtype], o)

	drop = o[:dropout] != 0
	setp(worldf, adam=true)
	setp(worldf, lr=o[:lr])
	if o[:pretrain]
		pretraining(worldf)
		if !drop
			setp(worldf, adam=false)
			setp(worldf, lr=0.00001)
		end
	end
	
	lasterr = besterr = 1e6
	best_epoch = 0
	anger = 0
	stopcriterion = false
	df = DataFrame(epoch = Int[], lr = Float64[], trn_err = Float64[], dev_err = Float64[], best_err = Float64[], best_epoch = Int[])
	loss1 = o[:predtype] == "loc" ? quadloss : softloss
	loss2 = o[:predtype] == "loc" ? quadloss : zeroone

	for epoch=1:o[:epochs]      # TODO: experiment with pretraining
		
		@date trnerr = train(worldf, worlddata[1], loss1; gclip=o[:gclip], dropout=drop)
		@date deverr = test(worldf, worlddata[2], loss2)

		if deverr < besterr
			besterr=deverr
			best_epoch = epoch
			o[:bestfile]!=nothing && save(o[:bestfile], "net", clean(net))
			anger = 0
		else
			anger += 1
		end
		if o[:patience] != 0 && anger == o[:patience]
			stopcriterion = true
			o[:lr] *= o[:decay]
			#setp(sentf, lr=o[:lr])
			#setp(worldf, lr=o[:lr])
			anger = 0
		end
		push!(df, (epoch, o[:lr], trnerr, deverr, besterr, best_epoch))
		println(df[epoch, :])
		if stopcriterion
			break
		end
		lasterr = deverr
	end

	#o[:savefile]!=nothing && save(o[:savefile], "net", clean(net))
	#@date devpred = predict(sentf, worldf, rawdata[2], get_worlds(rawworlddata[2]; batchsize=1); loc=o[:loc], xrange=xrange, xvocab=o[:xvocab], ftype=o[:ftype], xsparse=o[:xsparse])
	#println(devpred)
	o[:logfile]!=nothing && writetable(o[:logfile], df)
end
!isinteractive() && main(ARGS)