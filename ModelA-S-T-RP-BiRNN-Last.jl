using Knet
using ArgParse
using JLD
using CUDArt
using Knet: stack_isempty
using DataFrames
#gpu(false)

# RNN model:

@knet function birnnmodel(fword, bword; hidden=100, output=20, pdrop=0.5)
    fwvec = wdot(fword; out=hidden)                    
    bwvec = wdot(bword; out=hidden)
    fd = drop(fwvec; pdrop=pdrop)
    bd = drop(bwvec; pdrop=pdrop)
    fhidden = lstm(fd; out=hidden)
    bhidden = lstm(bd; out=hidden)
    fd2 = drop(fhidden; pdrop=pdrop)
    bd2 = drop(bhidden; pdrop=pdrop)
    fhidden2 = lstm(fd2; out=hidden)
    bhidden2 = lstm(bd2; out=hidden)

    if predict
        fdrop = drop(fhidden2; pdrop=pdrop)
        bdrop = drop(bhidden2; pdrop=pdrop)
        return wbf2(fdrop, bdrop; out=output, f=:soft)
    end
end

# Train and test scripts expect data to be an array of (s,p) pairs
# where s is an integer array of word indices
# and p is an integer class to be predicted

function train(f, data, loss; xvocab=326, yvocab=20, gclip=0)
    reset!(f)
    xforw = zeros(Float32, xvocab, 1)
    xback = zeros(Float32, xvocab, 1)
    y = zeros(Float32, yvocab, 1)
    err = 0
    for (s,p) in data
        for i in 1:length(s)
            wforw = s[i]
            wback = s[end-i+1]
            xforw[wforw] = xback[wback] = 1
            sforw(f, xforw, xback; predict = false, dropout = true)
            xforw[wforw] = xback[wback] = 0
        end
        eos = s[end]
        xforw[eos] = xback[eos] = 1
        ypred = sforw(f, xforw, xback; predict = true, dropout=true)
        xforw[eos] = xback[eos] = 0
        indmax(ypred)!=p && (err += 1)
        y[p] = 1; sback(f, y, loss); y[p] = 0
        while !stack_isempty(f); sback(f); end
        update!(f; gclip=gclip)
        reset!(f)
    end
    err / length(data)
end

function test(f, data, loss; xvocab=326, yvocab=20)
    reset!(f)
    xforw = zeros(Float32, xvocab, 1)
    xback = zeros(Float32, xvocab, 1)
    y = zeros(Float32, yvocab, 1)
    sumloss = numloss = 0
    for (s,p) in data
        for i in 1:length(s)
            wforw = s[i]
            wback = s[end-i+1]
            xforw[wforw] = xback[wback] = 1
            forw(f, xforw, xback; predict = false)
            xforw[wforw] = xback[wback] = 0
        end
        eos = s[end]
        xforw[eos] = xback[eos] = 1
        ypred = forw(f, xforw, xback; predict = true)
        xforw[eos] = xback[eos] = 0
        y[p] = 1; sumloss += loss(ypred, y); y[p] = 0
        numloss += 1
        reset!(f)
    end
    sumloss / numloss
end

function pred(f, data; xvocab=326, yvocab=20)
    reset!(f)
    xforw = zeros(Float32, xvocab, 1)
    xback = zeros(Float32, xvocab, 1)
    y = zeros(Float32, yvocab, 1)
    preds = Any[]
    for (s,p) in data
        for i in 1:length(s)
            wforw = s[i]
            wback = s[end-i+1]
            xforw[wforw] = xback[wback] = 1
            forw(f, xforw, xback; predict = false)
            xforw[wforw] = xback[wback] = 0
        end
        eos = s[end]
        xforw[eos] = xback[eos] = 1
        ypred = forw(f, xforw, xback; predict = true)
        push!(preds, indmax(to_host(ypred)))
        xforw[eos] = xback[eos] = 0
        reset!(f)
    end
    println(preds)
end


# Extract sentences, get rid of padding
function data2sent(data, nx)
    sent = Any[]
    for i=1:size(data,1)
        s = vec(data[i,1:nx])
        while s[end]==1; pop!(s); end
        push!(sent,s)
    end
    return sent
end

function main(args)
    s = ArgParseSettings()
    s.exc_handler=ArgParse.debug_handler
    @add_arg_table s begin
        ("--datafiles"; nargs='+'; default=["BlockWorld/logos/Train.STRP.data", "BlockWorld/logos/Dev.STRP.data"])
        ("--loadfile"; help="initialize model from file")
        ("--savefile"; help="save final model to file")
        ("--bestfile"; help="save best model to file")
        ("--target"; arg_type=Int; default=1; help="1:source,2:target,3:direction")
        ("--hidden"; arg_type=Int; default=100; help="hidden layer size")
        ("--epochs"; arg_type=Int; default=100; help="number of epochs to train")
        ("--lr"; arg_type=Float64; default=1.0; help="learning rate")
        ("--gclip"; arg_type=Float64; default=5.0; help="gradient clipping threshold")
        ("--dropout"; arg_type=Float64; default=0.5; help="dropout probability")
        ("--decay"; arg_type=Float64; default=0.9; help="learning rate decay if deverr increases")
        ("--gpu"; action = :store_true; help="use gpu, which is not used by default")
        ("--seed"; arg_type=Int; default=42; help="random number seed")
        ("--logfile")
    end
    isa(args, AbstractString) && (args=split(args))
    o = parse_args(args, s; as_symbols=true); println(o)
    o[:seed] > 0 && setseed(o[:seed])
    Knet.gpu(o[:gpu])

    # TODO: These are a bit hard-coded right now, probably should infer from data or make options.
    (nx, ny, xvocab, tvocab) = (79, 3, 326, [20, 20, 8])

    # Read data files: 6003x82, 855x82
    rawdata = map(f->readdlm(f,Int), o[:datafiles])

    # Extract sentences, get rid of padding
    sentences = map(d->data2sent(d,nx), rawdata)

    # Construct data sets
    # data[1]: source, data[2]: target, data[3]: direction
    # data[i][1]: train, data[i][2]: dev
    # data[i][j][k]: (sentence, answer) pair
    global data = Any[]
    for i = 1:3
        answers = map(d->vec(d[:,nx+i]), rawdata)
        d = map(zip, sentences, answers)
        push!(data, d)
    end

    # Train model for a dataset:
    epochs = 10
    yvocab = tvocab[o[:target]]
    mydata = data[o[:target]]
    global net = (o[:loadfile]!=nothing ? load(o[:loadfile], "net") :
                  compile(:birnnmodel; hidden=o[:hidden], output=yvocab, pdrop=o[:dropout]))
    setp(net, lr=o[:lr])
    setp(net, adam=true)
    lasterr = besterr = 1.0
    df = DataFrame(epoch = Int[], lr = Float64[], trn_err = Float64[], dev_err = Float64[], best_err = Float64[])
    for epoch=1:o[:epochs]      # TODO: experiment with pretraining
        @date trnerr = train(net, mydata[1], softloss; xvocab=xvocab, yvocab=yvocab, gclip=o[:gclip])
        @date deverr =  test(net, mydata[2], zeroone;  xvocab=xvocab, yvocab=yvocab)
        if deverr < besterr
            besterr=deverr
            o[:bestfile]!=nothing && save(o[:bestfile], "net", clean(net))
        end
        push!(df, (epoch, o[:lr], trnerr, deverr, besterr))
        println(df[epoch, :])

        #===
        if deverr > lasterr
            o[:lr] *= o[:decay]
            setp(net, lr=o[:lr])
        end
        ===#
    end
    o[:savefile]!=nothing && save(o[:savefile], "net", clean(net))
    pred(net, mydata[2])
   o[:logfile]!=nothing && writetable(o[:logfile], df)
end

!isinteractive() && main(ARGS)

# TODO: write minibatching versions, this is too slow, even slower on gpu, so run with gpu(false)
# For minibatching:
# Sentences will have to be padded in the beginning, so they end together.
# They need to be sorted by length.
# Each minibatch will be accompanied with a mask.
# Possible minibatch sizes to get the whole data:
# 6003 = 9 x 23 x 29
# 855 = 9 x 5 x 19

