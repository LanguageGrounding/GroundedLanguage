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

@knet function conv_layer(x; cwindow=0, cinput=0, coutput=0)
	w = par(init=Xavier(), dims=(2, cwindow, 3,coutput))
	c = conv(w,x)
	return c
end

@knet function conv2(x; cwindow=1, cinput=0, coutput=1)
	w2 = par(init=Xavier(), dims= (1, cwindow, cinput, coutput))
	c2 = conv(w2, x)
	return c2
end


function get_worldf(predtype, o)
	if predtype == "id" || predtype == "grid"
		@knet function output_layer(x; output=20)
			return wbf(x; out=output, f=:soft)
		end
	else
		@knet function output_layer(w, x; output=3)
			h = mul(w, x)
			h2 = wbf(h; out=300, f=:tanh)
			hd = drop(h2; pdrop=0.2)
			h3 = wbf(hd; out=100, f=:tanh)
			hd2 = drop(h3; pdrop=0.2)
			h4 = wbf(hd2; out=100, f=:tanh)
			hd3 = drop(h4; pdrop=0.2)
			h5 = wbf(hd3; out=100, f=:tanh)
			return wb(h5; out=output)
		end
	end

	@knet function cnn(x; cwin1=1, cout1=1)
		c1 = conv_layer(x; cwindow=cwin1, coutput=cout1)
		return c1
		#xyz = mul(y, c1)
		#return output_layer(xyz; output=output)
	end

	@knet function cnn2(x; cwin1=2, cout1=20, hidden=100, output=20)
		c1 = conv_layer(x; cwindow=cwin1, coutput=cout1)
		h = relu_layer(c1, output=hidden)
		return output_layer(h; output=output)
	end

	@knet function cnn3(x; cwin1=2, cout1=20, hidden=100, pdrop=0.5, output=20)
		c1 = conv_layer(x; cwindow=cwin1, coutput=cout1)
		h = relu_layer(c1, output=hidden)
		hd = drop(h; pdrop=pdrop)
		h2 = relu_layer(hd, output=hidden)
		return output_layer(h2; output=output)
	end

	outdim = predtype == "id" ? 20 : 18*18
	outdim = predtype == "loc" ? 3 : outdim
	worldf = nothing
	
	worldf = compile(:cnn; cwin1=o[:cwin], cout1=o[:cout])
	outputf = compile(:output_layer; output=outdim)
	return worldf, outputf
	
	#===========================
	if o[:chidden] == 0
		worldf = compile(:cnn; cwin1=o[:cwin], cout1=o[:cout])
		outputf = compile(:output_layer; output=outdim)
		return worldf, outputf
	elseif o[:chidden] != 0 && o[:dropout] == 0
		worldf = compile(:cnn2; cwin1=o[:cwin], cout1=o[:cout], hidden=o[:chidden], output=outdim)
	else
		worldf = compile(:cnn3; cwin1=o[:cwin], cout1=o[:cout], hidden=o[:chidden], pdrop=o[:dropout], output=outdim)
	end
	return worldf, nothing
	==============================#
end

function train(worldf, outputf, worlddata, loss; gclip=0, dropout=false)
	sumloss = numloss = 0
	reset!(worldf)
	i = 1
	for (x,y) in worlddata
		if dropout
			filters = forw(worldf, x)

			hfilters = to_host(filters)
			tmp = zeros(Float32, size(hfilters, 1), size(hfilters, 2), 3, size(hfilters, 4))
			for a=1:3; tmp[:,:,a,:] = hfilters; end#repmat does not work on matrices that have more than two dimensions
			filters = CudaArray(tmp)

			ypred = forw(outputf, filters, x[1,:,:,:], dropout=true)

		else
			filters = forw(worldf, x)

			hfilters = to_host(filters)
			tmp = zeros(Float32, size(hfilters, 1), size(hfilters, 2), 3, size(hfilters, 4))
			for a=1:3; tmp[:,:,a,:] = hfilters; end#repmat does not work on matrices that have more than two dimensions
			filters = CudaArray(tmp)

			ypred = forw(outputf, filters, x[1,:,:,:])
		end

		sumloss += size(y, 1) == 3 ? quadloss(ypred, y)*size(y,2) : zeroone(ypred, y)*size(y,2)
		numloss += size(y,2)

		gradw, _ = back(outputf, y, loss; getdx=true)
		hgradw = to_host(gradw)
		gradfilters = sum(hgradw, 3)

		back(worldf, gradfilters)

		update!(worldf; gclip=gclip)
		update!(outputf; gclip=gclip)
		reset!(worldf)
		reset!(outputf)
	end
	sumloss / numloss
end

function test(worldf, outputf, worlddata, loss, loc=false)
	sumloss = numloss = 0
	reset!(worldf)
	i = 1
	for (x,y) in worlddata
		filters = forw(worldf, x)
		hfilters = to_host(filters)
		tmp = zeros(Float32, size(hfilters, 1), size(hfilters, 2), 3, size(hfilters, 4))
		for a=1:3; tmp[:,:,a,:] = hfilters; end#repmat does not work on matrices that have more than two dimensions
		filters = CudaArray(tmp)
		ypred = forw(outputf, filters, x[1,:,:,:])
		
		sumloss += loss(ypred, y)*size(y,2)
		numloss += size(y,2)
		reset!(worldf)
		reset!(outputf)
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
function get_worlds(rawdata; batchsize=100, predtype = "id", ftype=Float32)
	#data = map(x -> (rawdata[x,1:end-64], rawdata[x,end-63:end]),1:size(rawdata,1));
	worlds = zeros(ftype, 2, 20, 3, size(rawdata, 1))

	ydim = 0
	if predtype == "id"
		ydim = 20
	elseif predtype == "loc"
		ydim = 3
	else
		ydim = 18 * 18
	end
	y = zeros(ftype, ydim, size(rawdata, 1))
	count = 0
	for indx=1:size(rawdata, 1)
		data = rawdata[indx, :]

		for i=1:20
			if !(data[1, (i-1)*3 + 1] == -1 && data[1, (i-1)*3 + 2] == -1 && data[1, (i-1)*3 + 3] == -1)
				for j=1:3
					worlds[1, i, j, indx] = data[1, (i-1)*3 + j]
					worlds[2, i, j, indx] = data[1, (i+19)*3 + j]
				end
			else
				count += 1
			end
		end
		
		if predtype == "id"
			source = round(Int, data[1, 222])
			y[source, indx] = 1
		elseif predtype == "loc"
			source = round(Int, data[1, 222])
			#y[:, indx] = worlds[1, source, :, indx]
			y[:, indx] = data[1, (source*3 - 2):(source*3)]
		else
			source = round(Int, data[1, 222])
			x = round(Int, data[1, (source*3 - 2)] / 0.1524) + 10
			z = round(Int, data[1, (source*3)] / 0.1524) + 10
			source = (z-1)*18 + x
			y[source, indx] = 1
		end
		
	end

	println("Count: $count")
	return minibatch(worlds, y, batchsize)
end

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
		r = randperm(size(d, 1))
		get_worlds(d[r, :], batchsize=o[:batchsize], predtype=o[:predtype])
	end
	
	worldf, outputf = get_worldf(o[:predtype], o)

	for net in (worldf, outputf); setp(net, adam=true); setp(net, lr=o[:lr]); end

	lasterr = besterr = 1e6
	best_epoch = 0
	anger = 0
	stopcriterion = false
	df = DataFrame(epoch = Int[], lr = Float64[], trn_err = Float64[], dev_err = Float64[], best_err = Float64[], best_epoch = Int[])
	loss1 = o[:predtype] == "loc" ? quadloss : softloss
	loss2 = o[:predtype] == "loc" ? quadloss : zeroone

	for epoch=1:o[:epochs]      # TODO: experiment with pretraining
		drop = o[:dropout] != 0
		
		@date trnerr = train(worldf, outputf, worlddata[1], loss1; gclip=o[:gclip], dropout=drop)
		@date deverr = test(worldf, outputf, worlddata[2], loss2)

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

	Knet.netprint(worldf)
	println("")
	Knet.netprint(outputf)
	println("")
	
	println("Filters:")
	println("First conv:")
	println(to_host(worldf.reg[2].out0))

	#=============================
	println("Second conv:")
	println("Size: $(size(to_host(outputf.reg[4].out0)))")
	println(to_host(outputf.reg[4].out0))
	============================#

	#println("")
	#println(worldf.reg[3].out0)
	#println("")
	#println(worldf.reg[4].out0)

	#o[:savefile]!=nothing && save(o[:savefile], "net", clean(net))
	#@date devpred = predict(sentf, worldf, rawdata[2], get_worlds(rawworlddata[2]; batchsize=1); loc=o[:loc], xrange=xrange, xvocab=o[:xvocab], ftype=o[:ftype], xsparse=o[:xsparse])
	#println(devpred)
	o[:logfile]!=nothing && writetable(o[:logfile], df)
end
!isinteractive() && main(ARGS)