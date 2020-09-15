"""
    ordinalgwas(nullformula, covfile, geneticfile)
    ordinalgwas(nullformula, df, geneticfile)
    ordinalgwas(fittednullmodel, geneticfile)
    ordinalgwas(fittednullmodel, bedfile, bimfile, bedn)

# Positional arguments 
- `nullformula::FormulaTerm`: formula for the null model.
- `covfile::AbstractString`: covariate file (csv) with one header line. One column 
    should be the ordinal phenotype coded as integers starting from 1.  For example, 
    ordinal phenotypes can be coded as 1, 2, 3, 4 but not 0, 1, 2, 3.  
- `df::DataFrame`: DataFrame containing response and regressors for null model.
- `geneticfile::AbstractString`: File containing genetic information for GWAS.
    This includes a PLINK file name without the bed, fam, or bim 
    extensions or a VCF file without the .vcf extension. If `geneticfile==nothing`, 
    only null model is fitted. If `geneticfile` is provided, bed, bim, and fam file (or vcf) with 
    same `geneticfile` prefix need to exist. Compressed file formats such as gz and bz2 
    are allowed. Check all allowed formats by `SnpArrays.ALLOWED_FORMAT`. If you're using a VCF file,
    make sure to use the `geneticformat = "VCF"` keyword option, and specificy dosage or genotype data
    with the `vcftype` command.
- `fittednullmodel::StatsModels.TableRegressionModel`: the fitted null model 
    output from `ordinalgwas(nullformula, covfile)` or `ordinalgwas(nullformula, df)`.
- `bedfile::Union{AbstractString,IOStream}`: path to Plink bed file with full file name.
- `bimfile::Union{AbstractString,IOStream}`: path to Plink bim file with full file name.
- `bedn::Integer`: number of samples in bed/vcf file.

# Keyword arguments
- `geneticformat`::AbstractString: Type of file used for the genetic analysis. 
`"PLINK"` and `"VCF"` are currently supported. Default is PLINK.
- `vcftype`::Union{Symbol, Nothing}: Data to extract from the VCF file for the GWAS analysis. 
`:DS` for dosage or `:GT` for genotypes. Default is nothing.
- `nullfile::Union{AbstractString, IOStream}`: output file for the fitted null model; 
    default is `ordinalgwas.null.txt`. 
- `pvalfile::Union{AbstractString, IOStream}`: output file for the gwas p-values; default is 
    `ordinalgwas.pval.txt`. 
- `covtype::Vector{DataType}`: type information for `covfile`. This is useful
    when `CSV.read(covarfile)` has parsing errors.  
- `covrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for covariate file.  
- `testformula::FormulaTerm`: formula for test unit. Default is `@formula(trait ~ 0 + snp)`.
- `test::Symbol`: `:score` (default) or `:lrt`.  
- `link::GLM.Link`: `LogitLink()` (default), `ProbitLink()`, `CauchitLink()`,
    or `CloglogLink()`.
- `snpmodel`: `ADDITIVE_MODEL` (default), `DOMINANT_MODEL`, or `RECESSIVE_MODEL`.
- `snpinds::Union{Nothing,AbstractVector{<:Integer}}`: SNP indices for bed/vcf file.
- `geneticrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for bed/vcf file.
- `solver`: an optimization solver supported by MathProgBase. Default is 
    `NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000)`. Another common choice is 
    `IpoptSolver(print_level=0)`.
- `verbose::Bool`: default is `false`.
"""
function ordinalgwas(
    # positional arguments
    nullformula::FormulaTerm,
    covfile::AbstractString,
    geneticfile::Union{Nothing, AbstractString} = nothing;
    # keyword arguments
    covtype::Union{Nothing, Vector{DataType}} = nothing,
    covrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    kwargs...
    )
    covdf = SnpArrays.makestream(covfile) do io
        CSV.read(io, DataFrame; types=covtype)
    end
    ordinalgwas(nullformula, covrowinds == nothing ? covdf : covdf[covrowinds, :], 
        geneticfile; kwargs...)
end

function ordinalgwas(
    nullformula::FormulaTerm,
    nulldf::DataFrame,
    geneticfile::Union{Nothing, AbstractString} = nothing;
    nullfile::Union{AbstractString, IOStream} = "ordinalgwas.null.txt",
    link::GLM.Link = LogitLink(),
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false,
    kwargs...
    )
    # fit and output null model
    nm = polr(nullformula, nulldf, link, solver)
    verbose && show(nm)
    SnpArrays.makestream(nullfile, "w") do io
        show(io, nm)
    end
    geneticfile == nothing && (return nm)
    ordinalgwas(nm, geneticfile; solver=solver, verbose=verbose, kwargs...)
end

function ordinalgwas(
    # positional arguments
    fittednullmodel::StatsModels.TableRegressionModel,
    geneticfile::AbstractString;
    # keyword arguments
    geneticformat::AbstractString = "PLINK",
    vcftype::Union{Symbol, Nothing} = nothing,
    testformula::FormulaTerm = fittednullmodel.mf.f.lhs ~ Term(:snp),
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwas.pval.txt",
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    geneticrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )

    # locate plink bed, fam, bim files or VCF file
    isplink = occursin("plink", lowercase(geneticformat))
    if isplink
        if isfile(geneticfile * ".bed")
            bedfile = geneticfile * ".bed"
        else
            fmt = findfirst(isfile, geneticfile * ".bed." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("bed file not found"))
            bedfile = geneticfile * ".bed." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        famfile = replace(bedfile, ".bed" => ".fam")
        isfile(famfile) || throw(ArgumentError("fam file not found"))
        bimfile = replace(bedfile, ".bed" => ".bim")
        isfile(bimfile) || throw(ArgumentError("bim file not found"))
        # selected rows should match nobs in null model
        bedn = SnpArrays.makestream(countlines, famfile)
    else
        vcftype in [:GT, :DS] || throw(ArgumentError("vcftype not specified. Allowable types are :GT for genotypes and :DS for dosages."))
        if isfile(geneticfile * ".vcf")
            vcffile = geneticfile * ".vcf"
        else
            fmt = findfirst(isfile, geneticfile * ".vcf." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("VCF file not found"))
            vcffile = geneticfile * ".vcf." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        bedn = VCFTools.nsamples(vcffile)
    end
    if geneticrowinds == nothing
        nbedrows = bedn
        rowinds = 1:bedn
    else
        nbedrows = eltype(geneticrowinds) == Bool ? count(geneticrowinds) : length(geneticrowinds)
        rowinds = geneticrowinds
    end
    nbedrows == nobs(fittednullmodel) || 
        throw(ArgumentError("number of samples in geneticrowinds does not match null model"))

    # validate testing method
    test = Symbol(lowercase(string(test)))
    test == :score || test == :lrt || throw(ArgumentError("unrecognized test $test"))

    # gwas
    if isplink #plink
        ordinalgwas(fittednullmodel, bedfile, bimfile, bedn; 
            testformula = testformula, 
            test = test, 
            pvalfile = pvalfile,
            snpmodel = snpmodel, 
            snpinds = snpinds, 
            bedrowinds = rowinds, 
            solver = solver, 
            verbose = verbose)
    else #vcf
        ordinalgwas(fittednullmodel, vcffile, bedn, vcftype; 
            testformula = testformula, 
            test = test, 
            pvalfile = pvalfile,
            snpmodel = snpmodel, 
            snpinds = snpinds, 
            vcfrowinds = rowinds, 
            solver = solver, 
            verbose = verbose)
    end
end

# For PLINK Analysis
function ordinalgwas(
    fittednullmodel::StatsModels.TableRegressionModel,
    bedfile::Union{AbstractString, IOStream}, # full path and bed file name
    bimfile::Union{AbstractString, IOStream}, # full path and bim file name
    bedn::Integer;           # number of samples in bed file
    testformula::FormulaTerm = fittednullmodel.mf.f.lhs ~ Term(:snp),
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwas.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    bedrowinds::AbstractVector{<:Integer} = 1:bedn, # row indices for SnpArray
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # create SnpArray
    genomat = SnpArrays.SnpArray(bedfile, bedn)
    # extra columns in design matrix to be tested
    testdf = DataFrame(fittednullmodel.mf.data) # TODO: not type stable here
    testdf[!, :snp] = zeros(size(fittednullmodel.mm, 1))
    #mfalt = ModelFrame(testformula, testdf)
    #mfalt.terms.intercept = false # drop intercept
    #Z = similar(ModelMatrix(mfalt).m)
    Z = similar(modelmatrix(testformula, testdf))
    # create SNP mask vector
    if snpinds == nothing
        snpmask = trues(SnpArrays.makestream(countlines, bimfile))
    elseif eltype(snpinds) == Bool
        snpmask = snpinds
    else
        snpmask = falses(SnpArrays.makestream(countlines, bimfile))
        snpmask[snpinds] .= true
    end
    # carry out score or LRT test SNP by SNP
    snponly = testformula.rhs == Term(:snp)
    cc = SnpArrays.counts(genomat, dims=1) # column counts of genomat
    if test == :score
        ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
        SnpArrays.makestream(pvalfile, "w") do io
            println(io, "chr,pos,snpid,maf,hwepval,pval")
            SnpArrays.makestream(bimfile) do bimio
                for j in eachindex(snpmask)
                    row = readline(bimio)
                    snpmask[j] || continue
                    hwepval = SnpArrays.hwe(cc[1, j], cc[3, j], cc[4, j])
                    maf = (cc[3, j] + 2cc[4, j]) / 2(cc[1, j] + cc[3, j] + cc[4, j])
                    maf > 0.5 && (maf = 1 - maf)
                    if maf == 0 # mono-allelic
                        pval = 1.0
                    else
                        if snponly
                            copyto!(ts.Z, @view(genomat[bedrowinds, j]), impute=true, model=snpmodel)
                        else # snp + other terms
                            copyto!(testdf[!, :snp], @view(genomat[bedrowinds, j]), impute=true, model=snpmodel)
                            #mfalt = ModelFrame(testformula, testdf)
                            #mfalt.terms.intercept = false # drop intercept
                            #ts.Z[:] = ModelMatrix(mfalt).m
                            ts.Z[:] = modelmatrix(testformula, testdf)
                        end
                        pval = polrtest(ts)
                    end
                    snpj = split(row)
                    println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$maf,$hwepval,$pval")
                end
            end
        end
    elseif test == :lrt
        nulldev = deviance(fittednullmodel.model)
        Xaug = [fittednullmodel.model.X Z]
        q = size(Z, 2)
        γ̂ = Vector{Float64}(undef, q) # effect size for columns being tested
        SnpArrays.makestream(pvalfile, "w") do io
            if snponly
                println(io, "chr,pos,snpid,maf,hwepval,effect,pval")
            else
                print(io, "chr,pos,snpid,maf,hwepval,")
                for j in 1:q
                    print(io, "effect$j,")
                end
                println(io, "pval")
            end
            SnpArrays.makestream(bimfile) do bimio
                for j in eachindex(snpmask)
                    row = readline(bimio)
                    snpmask[j] || continue
                    maf = (cc[3, j] + 2cc[4, j]) / 2(cc[1, j] + cc[3, j] + cc[4, j])
                    maf > 0.5 && (maf = 1 - maf)
                    hwepval = SnpArrays.hwe(cc[1, j], cc[3, j], cc[4, j])
                    if maf == 0 # mono-allelic
                        fill!(γ̂, 0)
                        pval = 1.0
                    else
                        if snponly
                            copyto!(@view(Xaug[:, fittednullmodel.model.p+1]), 
                                @view(genomat[bedrowinds, j]), 
                                impute=true, model=snpmodel)
                        else # snp + other terms
                            copyto!(testdf[!, :snp], @view(genomat[bedrowinds, j]), 
                                impute=true, model=snpmodel)
                            #mfalt = ModelFrame(testformula, testdf)
                            #mfalt.terms.intercept = false # drop intercept
                            #Xaug[:, fittednullmodel.model.p+1:end] = ModelMatrix(mfalt).m
                            Xaug[:, fittednullmodel.model.p+1:end] = modelmatrix(testformula, testdf)
                        end
                        altmodel = polr(Xaug, fittednullmodel.model.Y, 
                            fittednullmodel.model.link, solver, 
                            wts = fittednullmodel.model.wts)
                        copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                        pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                    end
                    snpj = split(row)
                    if snponly
                        println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$maf,$hwepval,$(γ̂[1]),$pval")
                    else
                        print(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$maf,$hwepval,")
                        for j in 1:q
                            print(io, "$(γ̂[j]),")
                        end
                        println(io, pval)
                    end
                end
            end
        end
    end
    return fittednullmodel
end

# For VCF Analysis
function ordinalgwas(
    fittednullmodel::StatsModels.TableRegressionModel,
    vcffile::Union{AbstractString, IOStream}, # full path and vcf file name
    nsamples::Integer,          # number of samples in bed file
    vcftype::Symbol;           # :GT = genotype, :DS = dosage
    testformula::FormulaTerm = fittednullmodel.mf.f.lhs ~ Term(:snp),
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwas.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    vcfrowinds::AbstractVector{<:Integer} = 1:nsamples, # row indices for VCF array
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # get number of SNPs in file
    nsnps = nrecords(vcffile)
    # create holders for chromome, position, id 
    rec_chr = Array{Any, 1}(undef, 1)
    rec_pos = Array{Any, 1}(undef, 1)
    rec_ids = Array{Any, 1}(undef, 1)
    gholder = zeros(Union{Missing, Float64}, nsamples)
    # extra columns in design matrix to be tested
    testdf = DataFrame(fittednullmodel.mf.data) # TODO: not type stable here
    testdf[!, :snp] = zeros(size(fittednullmodel.mm, 1))
    Z = similar(modelmatrix(testformula, testdf))

    # for VCFTools, snpmodel is coded differently 
    snpmodel = modelingdict[snpmodel]

    # create SNP mask vector
    if snpinds == nothing
        snpmask = trues(nsnps)
    elseif eltype(snpinds) == Bool
        snpmask = snpinds
    else
        snpmask = falses(nsnps)
        snpmask[snpinds] .= true
    end

    # carry out score or LRT test SNP by SNP
    snponly = testformula.rhs == Term(:snp)
    # cc = SnpArrays.counts(genomat, dims=1) # column counts of genomat
    reader = VCF.Reader(openvcf(vcffile))
    if test == :score
        ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
        SnpArrays.makestream(pvalfile, "w") do io
            println(io, "chr,pos,snpid,pval")
            for j in eachindex(snpmask)
                if !snpmask[j] #skip snp, must read marker still. 
                    copy_gt!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    continue
                end
                if vcftype == :GT #genotype 
                    copy_gt!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                else #dosage
                    copy_ds!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                end
                if snponly
                    copyto!(ts.Z, @view(gholder[vcfrowinds]))
                else # snp + other terms
                    copyto!(testdf[!, :snp], @view(gholder[vcfrowinds]))
                    ts.Z[:] = modelmatrix(testformula, testdf)
                end
                pval = polrtest(ts)
                println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),$pval")
            end
        end
    elseif test == :lrt
        nulldev = deviance(fittednullmodel.model)
        Xaug = [fittednullmodel.model.X Z]
        q = size(Z, 2)
        γ̂ = Vector{Float64}(undef, q) # effect size for columns being tested
        SnpArrays.makestream(pvalfile, "w") do io
            if snponly
                println(io, "chr,pos,snpid,effect,pval")
            else
                print(io, "chr,pos,snpid,")
                for j in 1:q
                    print(io, "effect$j,")
                end
                println(io, "pval")
            end
            for j in eachindex(snpmask)
                if !snpmask[j] #skip snp, must read marker still. 
                    copy_gt!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    continue
                end
                if vcftype == :GT #genotype 
                    copy_gt!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                else #dosage
                    copy_ds!(gholder, reader; model = snpmodel, impute = true,
                    record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                end
                if snponly
                    copyto!(@view(Xaug[:, fittednullmodel.model.p+1]), 
                        @view(gholder[vcfrowinds]))
                else # snp + other terms
                    copyto!(testdf[!, :snp], @view(gholder[vcfrowinds]))
                    Xaug[:, fittednullmodel.model.p+1:end] = modelmatrix(testformula, testdf)
                end
                altmodel = polr(Xaug, fittednullmodel.model.Y, 
                    fittednullmodel.model.link, solver, 
                    wts = fittednullmodel.model.wts)
                copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                if snponly
                    println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),$(γ̂[1]),$pval")
                else
                    print(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),")
                    for j in 1:q
                        print(io, "$(γ̂[j]),")
                    end
                    println(io, pval)
                end
            end
        end
    end
    close(reader)
    return fittednullmodel
end

#Snp-Set Analysis
#gets rid of snpmask (snpinds) and testformula 
#no longer outputs maf and hwe
"""
    ordinalsnpsetgwas(nullformula, covfile, geneticfile)
    ordinalsnpsetgwas(nullformula, df, geneticfile)
    ordinalsnpsetgwas(fittednullmodel, geneticfile)
    ordinalsnpsetgwas(fittednullmodel, bedfile, bimfile, bedn)

# Positional arguments 
- `nullformula::FormulaTerm`: formula for the null model.
- `covfile::AbstractString`: covariate file (csv) with one header line. One column 
    should be the ordinal phenotype coded as integers starting from 1.  For example, 
    ordinal phenotypes can be coded as 1, 2, 3, 4 but not 0, 1, 2, 3.  
- `df::DataFrame`: DataFrame containing response and regressors for null model.
- `geneticfile::AbstractString`: File containing genetic information for GWAS.
    This includes a PLINK file name without the bed, fam, or bim 
    extensions or a VCF file without the .vcf extension. If `geneticfile==nothing`, 
    only null model is fitted. If `geneticfile` is provided, bed, bim, and fam file (or vcf) with 
    same `geneticfile` prefix need to exist. Compressed file formats such as gz and bz2 
    are allowed. Check all allowed formats by `SnpArrays.ALLOWED_FORMAT`. If you're using a VCF file,
    make sure to use the `geneticformat = "VCF"` keyword option, and specificy dosage or genotype data
    with the `vcftype` command.
- `fittednullmodel::StatsModels.TableRegressionModel`: the fitted null model 
    output from `ordinalgwas(nullformula, covfile)` or `ordinalgwas(nullformula, df)`.
- `bedfile::Union{AbstractString,IOStream}`: path to Plink bed file with full file name.
- `bimfile::Union{AbstractString,IOStream}`: path to Plink bim file with full file name.
- `bedn::Integer`: number of samples in bed file.

# Keyword arguments
- `geneticformat`::Union{AbstractString}: Type of file used for the genetic analysis. 
`"PLINK"` and `"VCF"` are currently supported. Default is PLINK.
- `vcftype`::Union{Symbol, Nothing}: Data to extract from the VCF file for the GWAS analysis. 
`:DS` for dosage or `:GT` for genotypes. Default is nothing.
- `nullfile::Union{AbstractString, IOStream}`: output file for the fitted null model; 
    default is `ordinalgwas.null.txt`. 
- `pvalfile::Union{AbstractString, IOStream}`: output file for the gwas p-values; default is 
    `ordinalgwas.pval.txt`. 
- `snpset::Union{Nothing, Integer, AbstractString, AbstractVector{<:Integer}}`: Only include 
    if you are conducting a snpset analysis. An integer indicates a window of SNPs 
    (i.e. every 500 snps). An abstract string allows you to specify an input file, 
    with no header and two columns separated by a space. The first column must contain the snpset ID
    and the second column must contain the snpid's identical to the bimfile. An AbstractVector
    allows you to specify the snps you want to perform one joint snpset test for.
- `covtype::Vector{DataType}`: type information for `covfile`. This is useful
    when `CSV.read(covarfile)` has parsing errors.  
- `covrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for covariate file.  
- `test::Symbol`: `:score` (default) or `:lrt`.  
- `link::GLM.Link`: `LogitLink()` (default), `ProbitLink()`, `CauchitLink()`,
    or `CloglogLink()`.
- `snpmodel`: `ADDITIVE_MODEL` (default), `DOMINANT_MODEL`, or `RECESSIVE_MODEL`.
- `snpinds::Union{Nothing,AbstractVector{<:Integer}}`: SNP indices for bed/vcf file.
- `geneticrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for bed/vcf file.
- `solver`: an optimization solver supported by MathProgBase. Default is 
    `NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000)`. Another common choice is 
    `IpoptSolver(print_level=0)`.
- `verbose::Bool`: default is `false`.
"""
function ordinalsnpsetgwas(
    # positional arguments
    nullformula::FormulaTerm,
    covfile::AbstractString,
    geneticfile::Union{Nothing, AbstractString} = nothing;
    # keyword arguments
    covtype::Union{Nothing, Vector{DataType}} = nothing,
    covrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    kwargs...
    )
    covdf = SnpArrays.makestream(covfile) do io
        CSV.read(io, DataFrame; types=covtype)
    end
    ordinalsnpsetgwas(nullformula, covrowinds == nothing ? covdf : covdf[covrowinds, :], 
        geneticfile; kwargs...)
end

function ordinalsnpsetgwas(
    nullformula::FormulaTerm,
    nulldf::DataFrame,
    geneticfile::Union{Nothing, AbstractString} = nothing;
    nullfile::Union{AbstractString, IOStream} = "ordinalgwas.null.txt",
    link::GLM.Link = LogitLink(),
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false,
    kwargs...
    )
    # fit and output null model
    nm = polr(nullformula, nulldf, link, solver)
    verbose && show(nm)
    SnpArrays.makestream(nullfile, "w") do io
        show(io, nm)
    end
    geneticfile == nothing && (return nm)
    ordinalsnpsetgwas(nm, geneticfile; solver=solver, verbose=verbose, kwargs...)
end

function ordinalsnpsetgwas(
    # positional arguments
    fittednullmodel::StatsModels.TableRegressionModel,
    geneticfile::AbstractString;
    # keyword arguments
    geneticformat::AbstractString = "PLINK",
    vcftype::Union{Symbol, Nothing} = nothing,
    snpset::Union{Nothing, Integer, AbstractString, AbstractVector{<:Integer}} = nothing,
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwas.pval.txt",
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    geneticrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # locate plink bed, fam, bim files or VCF file
    isplink = occursin("plink", lowercase(geneticformat))
    if isplink
        if isfile(geneticfile * ".bed")
            bedfile = geneticfile * ".bed"
        else
            fmt = findfirst(isfile, geneticfile * ".bed." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("bed file not found"))
            bedfile = geneticfile * ".bed." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        famfile = replace(bedfile, ".bed" => ".fam")
        isfile(famfile) || throw(ArgumentError("fam file not found"))
        bimfile = replace(bedfile, ".bed" => ".bim")
        isfile(bimfile) || throw(ArgumentError("bim file not found"))
        # selected rows should match nobs in null model
        bedn = SnpArrays.makestream(countlines, famfile)
    else
        vcftype in [:GT, :DS] || throw(ArgumentError("vcftype not specified. Allowable types are :GT for genotypes and :DS for dosages."))
        if isfile(geneticfile * ".vcf")
            vcffile = geneticfile * ".vcf"
        else
            fmt = findfirst(isfile, geneticfile * ".vcf." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("VCF file not found"))
            vcffile = geneticfile * ".vcf." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        bedn = VCFTools.nsamples(vcffile)
    end
    if geneticrowinds == nothing
        nbedrows = bedn
        rowinds = 1:bedn
    else
        nbedrows = eltype(geneticrowinds) == Bool ? count(geneticrowinds) : length(geneticrowinds)
        rowinds = geneticrowinds
    end
    nbedrows == nobs(fittednullmodel) || 
        throw(ArgumentError("number of samples in geneticrowinds does not match null model"))
    # validate testing method
    test = Symbol(lowercase(string(test)))
    test == :score || test == :lrt || throw(ArgumentError("unrecognized test $test"))
    # gwas
    if isplink #plink
        ordinalsnpsetgwas(fittednullmodel, bedfile, bimfile, bedn; 
        test = test, 
        pvalfile = pvalfile,
        snpmodel = snpmodel, 
        snpset = snpset, 
        bedrowinds = rowinds, 
        solver = solver, 
        verbose = verbose)
    else #vcf
        ordinalsnpsetgwas(fittednullmodel, vcffile, bedn, vcftype; 
        test = test, 
        pvalfile = pvalfile,
        snpmodel = snpmodel, 
        snpset = snpset, 
        vcfrowinds = rowinds, 
        solver = solver, 
        verbose = verbose)
    end
end

# For PLINK Analysis
function ordinalsnpsetgwas(
    fittednullmodel::StatsModels.TableRegressionModel,
    bedfile::Union{AbstractString, IOStream}, # full path and bed file name
    bimfile::Union{AbstractString, IOStream}, # full path and bim file name
    bedn::Integer;           # number of samples in bed file
    snpset::Union{Nothing, Integer, AbstractString, AbstractVector{<:Integer}} = nothing,
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalsnpsetgwas.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    bedrowinds::AbstractVector{<:Integer} = 1:bedn, # row indices for SnpArray
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # create SnpArray
    genomat = SnpArrays.SnpArray(bedfile, bedn)
    mafs = SnpArrays.maf(genomat)
    # determine type of snpset analysis 
    if isa(snpset, Nothing)
        setlength = 1
    elseif isa(snpset, AbstractString)
        isfile(snpset) || throw(ArgumentError("snpset file not found, 
        to specify a window replace snpset string with a window size"))
        #first column SNPset ID, second column SNP ID
        snpsetFile = CSV.read(snpset, DataFrame, header = [:snpset_id, :snp_id], delim = " ")
        #make sure it matches bim file
        biminfo = CSV.read(bimfile, DataFrame, header = [:chr, :snp_id, :c3, :bp, :c5, :c6], delim = "\t")
        snpsetFile[!, :snp_id] == biminfo[!, :snp_id] || throw(ArgumentError("snp order in snpset file
        must match (in the same order) bimfile")) 
        snpset_ids = unique(snpsetFile[!, :snpset_id])
        nSets = length(snpset_ids)
        setlength = 0
    elseif isa(snpset, Integer)
        setlength = snpset
    else #abstract vector (boolean of true at indicies or range or indicies)
        setlength = -1
    end
    if setlength > 0 #single snp analysis or window
        Z = zeros(size(fittednullmodel.mm, 1), setlength) # column counts of genomat
        totalsnps = SnpArrays.makestream(countlines, bimfile)
        if test == :score
            ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
            SnpArrays.makestream(pvalfile, "w") do io
                println(io, "startchr,startpos,startsnpid,endchr,endpos,endsnpid,pval")
                SnpArrays.makestream(bimfile) do bimio
                    #for j in eachindex(snpmask)
                    q = setlength
                    for j in 1:q:totalsnps
                        endj = j + q - 1  
                        rowj = readline(bimio)  
                        if endj >= totalsnps
                            endj = totalsnps
                            #global setlength = totalsnps - j + 1
                            q = totalsnps - j + 1
                            #length of Z will be different
                            #global Z = zeros(size(fittednullmodel.mf.df, 1), q)
                            #global ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                            Z = zeros(size(fittednullmodel.mm, 1), q)
                            ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                        end
                        for i in 1:(q - 2) #
                            readline(bimio)
                        end
                        endj == totalsnps ? rowj_s = rowj : rowj_s = readline(bimio)
                        if all(@view(mafs[j:endj]) .== 0) # all mono-allelic, unlikely but just in case
                            pval = 1.0
                        else
                            copyto!(ts.Z, @view(genomat[bedrowinds, j:endj]), impute=true, model=snpmodel)
                            pval = polrtest(ts)
                        end
                        snpj = split(rowj)
                        snpj_s = split(rowj_s)
                        println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$(snpj_s[1]),",
                        "$(snpj_s[4]),$(snpj_s[2]),$pval")
                    end
                end
            end
        elseif test == :lrt
            nulldev = deviance(fittednullmodel.model)
            Xaug = [fittednullmodel.model.X Z]
            γ̂ = Vector{Float64}(undef, setlength) # effect size for columns being tested
            SnpArrays.makestream(pvalfile, "w") do io
                println(io, "startchr,startpos,startsnpid,endchr,",
                "endpos,endsnpid,l2normeffect,pval")
                SnpArrays.makestream(bimfile) do bimio
                    q = setlength
                    for j in 1:q:totalsnps
                        endj = j + q - 1  
                        rowj = readline(bimio)  
                        if endj >= totalsnps
                            endj = totalsnps
                            q = totalsnps - j + 1
                            Xaug = [fittednullmodel.model.X zeros(size(
                                fittednullmodel.mm, 1), q)]
                        end
                        for i in 1:(q - 2)
                            readline(bimio)
                        end
                        endj == totalsnps ? rowj_s = rowj : rowj_s = readline(bimio)
                        if all(@view(mafs[j:endj]) .== 0) # all mono-allelic, unlikely but just in case
                            fill!(γ̂, 0)
                            pval = 1.0
                        else
                            copyto!(@view(Xaug[:, (fittednullmodel.model.p+1):end]), 
                                    @view(genomat[bedrowinds, j:endj]), 
                                    impute=true, model=snpmodel)
                            altmodel = polr(Xaug, fittednullmodel.model.Y, 
                                fittednullmodel.model.link, solver, 
                                wts = fittednullmodel.model.wts)
                            copyto!(γ̂, @view(altmodel.β[(fittednullmodel.model.p+1):end]))#, fittednullmodel.model.p + 1, setlength)
                            l2normeffect = norm(γ̂)
                            pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                        end
                        snpj = split(rowj)
                        snpj_s = split(rowj_s)
                        println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),",
                        "$(snpj_s[1]),$(snpj_s[4]),$(snpj_s[2]),$l2normeffect,$pval")
                    end
                end
            end
        end
    elseif setlength == 0 #snpset is defined by snpset file
        SnpArrays.makestream(pvalfile, "w") do io
            test == :score ? println(io, "snpsetid,nsnps,pval") : println(io, 
                "snpsetid,nsnps,l2normeffect,pval")
            for j in eachindex(snpset_ids)
                snpset_id = snpset_ids[j]
                snpinds = findall(snpsetFile[!, :snpset_id] .== snpset_id)
                q = length(snpinds)
                Z = zeros(size(fittednullmodel.mm, 1), q)
                γ̂ = Vector{Float64}(undef, q)
                Xaug = [fittednullmodel.model.X Z]
                if all(@view(mafs[snpinds]) .== 0) # all mono-allelic, unlikely but just in case
                    pval = 1.0
                    l2normeffect = 0.0
                    test == :score ? println(io, "$(snpset_id),$q,$pval") : 
                    println(io, "$(snpset_id),$q,$l2normeffect,$pval")
                else
                    if test == :score
                        ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                        copyto!(ts.Z, @view(genomat[bedrowinds, snpinds]), impute=true,
                         model=snpmodel)
                        pval = polrtest(ts)
                        println(io, "$(snpset_id),$q,$pval")
                    elseif test == :lrt
                        nulldev = deviance(fittednullmodel.model)
                        copyto!(@view(Xaug[:, fittednullmodel.model.p+1:end]), 
                                @view(genomat[bedrowinds, snpinds]), 
                                impute=true, model=snpmodel)
                        altmodel = polr(Xaug, fittednullmodel.model.Y, 
                            fittednullmodel.model.link, solver, 
                            wts = fittednullmodel.model.wts)
                        copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                        l2normeffect = norm(γ̂)
                        pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                        println(io, "$(snpset_id),$q,$l2normeffect,$pval")
                    end
                end
            end
        end
    else #setlength == -1 (testing just one set with specified snps in snpset)
        SnpArrays.makestream(pvalfile, "w") do io
            if all(@view(mafs[snpset]) .== 0) # all mono-allelic, unlikely but just in case
                pval = 1.0
                l2normeffect = 0.0
            else
                q = length(snpset)
                γ̂ = Vector{Float64}(undef, q)
                Z = zeros(size(fittednullmodel.mm, 1), q)
                if test == :score
                    ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                    copyto!(ts.Z, @view(genomat[bedrowinds, snpset]), impute=true, model=snpmodel)
                    pval = polrtest(ts)
                    println(io, "The joint pvalue of snps indexed",
                     " at $(snpset) is $pval")
                elseif test == :lrt
                    nulldev = deviance(fittednullmodel.model)
                    Xaug = [fittednullmodel.model.X Z]
                    copyto!(@view(Xaug[:, fittednullmodel.model.p+1:end]), 
                            @view(genomat[bedrowinds, snpset]), 
                            impute=true, model=snpmodel)
                    altmodel = polr(Xaug, fittednullmodel.model.Y, 
                        fittednullmodel.model.link, solver, 
                        wts = fittednullmodel.model.wts)
                    copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                    l2normeffect = norm(γ̂)
                    pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                    println(io, "The l2norm of the effect size vector",
                    " is $l2normeffect and joint pvalue of snps indexed", 
                    " at $(snpset) is $pval")
                end
            end
        end
    end
    return fittednullmodel
end

# For VCF Analysis
function ordinalsnpsetgwas(
    fittednullmodel::StatsModels.TableRegressionModel,
    vcffile::Union{AbstractString, IOStream}, # full path and bed file name
    nsamples::Integer,
    vcftype::Symbol;           # number of samples in bed file
    snpset::Union{Nothing, Integer, AbstractString, AbstractVector{<:Integer}} = nothing,
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalsnpsetgwas.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    vcfrowinds::AbstractVector{<:Integer} = 1:nsamples, # row indices for SnpArray
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # get number of SNPs in file
    nsnps = nrecords(vcffile)

    # for VCFTools, snpmodel is coded differently 
    snpmodel = modelingdict[snpmodel]

    # max size of a snpset length
    maxsnpset = 1

    #determine snpset
    if isa(snpset, Nothing)
        setlength = 1
        maxsnpset = 1
    elseif isa(snpset, AbstractString)
        isfile(snpset) || throw(ArgumentError("snpset file not found, 
        to specify a window replace snpset string with a window size"))
        #first column SNPset ID, second column SNP ID
        snpsetFile = CSV.read(snpset, DataFrame, header = [:snpset_id, :snp_id], delim = " ")
        maxsnpset = combine(groupby(snpsetFile, :snpset_id), :snp_id => length => :snpset_length) |> 
            x -> maximum(x.snpset_length)
        snpset_ids = unique(snpsetFile[!, :snpset_id])
        nSets = length(snpset_ids)
        setlength = 0
    elseif isa(snpset, Integer)
        setlength = snpset
        maxsnpset = snpset 
    else #abstract vector (boolean of true at indicies or range or indicies)
        setlength = -1
        maxsnpset = count(snpset .!= 0)
    end

    # create holders for chromome, position, id 
    rec_chr = Array{Any, 1}(undef, maxsnpset)
    rec_pos = Array{Any, 1}(undef, maxsnpset)
    rec_ids = Array{Any, 1}(undef, maxsnpset)
    gholder = zeros(Union{Missing, Float64}, nsamples, maxsnpset)

    reader = VCF.Reader(openvcf(vcffile))
    if setlength > 0 #single snp analysis or window
        Z = zeros(size(fittednullmodel.mm, 1), setlength) # column counts of genomat
        if test == :score
            ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
            SnpArrays.makestream(pvalfile, "w") do io
                println(io, "startchr,startpos,startsnpid,endchr,endpos,endsnpid,pval")
                q = setlength
                for j in 1:q:nsnps
                    endj = j + q - 1    
                    if endj >= nsnps
                        endj = nsnps
                        q = nsnps - j + 1
                        #length of Z will be different
                        gholder = zeros(Union{Missing, Float64}, nsamples, q)
                        rec_chr = Array{Any, 1}(undef, q)
                        rec_pos = Array{Any, 1}(undef, q)
                        rec_ids = Array{Any, 1}(undef, q)
                        Z = zeros(size(fittednullmodel.mm, 1), q)
                        ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                    end
                    if vcftype == :GT #genotype 
                        copy_gt!(gholder, reader; model = snpmodel, impute = true,
                        record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    else #dosage
                        copy_ds!(gholder, reader; model = snpmodel, impute = true,
                        record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    end
                    copyto!(ts.Z, @view(gholder[vcfrowinds]))
                    pval = polrtest(ts)
                    println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),",
                    "$(rec_chr[end]),$(rec_pos[end]),$(rec_ids[end][end]),$pval")
                end
            end
        elseif test == :lrt
            nulldev = deviance(fittednullmodel.model)
            Xaug = [fittednullmodel.model.X Z]
            γ̂ = Vector{Float64}(undef, setlength) # effect size for columns being tested
            SnpArrays.makestream(pvalfile, "w") do io
                println(io, "startchr,startpos,startsnpid,endchr,",
                "endpos,endsnpid,l2normeffect,pval")
                q = setlength
                for j in 1:q:nsnps
                    endj = j + q - 1  
                    if endj >= nsnps
                        endj = nsnps
                        q = nsnps - j + 1
                        Xaug = [fittednullmodel.model.X zeros(size(
                            fittednullmodel.mm, 1), q)]
                        gholder = zeros(Union{Missing, Float64}, nsamples, q)
                        rec_chr = Array{Any, 1}(undef, q)
                        rec_pos = Array{Any, 1}(undef, q)
                        rec_ids = Array{Any, 1}(undef, q)
                    end
                    if vcftype == :GT #genotype 
                        copy_gt!(gholder, reader; model = snpmodel, impute = true,
                        record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    else #dosage
                        copy_ds!(gholder, reader; model = snpmodel, impute = true,
                        record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                    end
                    copyto!(@view(Xaug[:, (fittednullmodel.model.p+1):end]), 
                        @view(gholder[vcfrowinds]))
                    altmodel = polr(Xaug, fittednullmodel.model.Y, 
                        fittednullmodel.model.link, solver, 
                        wts = fittednullmodel.model.wts)
                    copyto!(γ̂, @view(altmodel.β[(fittednullmodel.model.p+1):end]))#, fittednullmodel.model.p + 1, setlength)
                    l2normeffect = norm(γ̂)
                    pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                    println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),",
                    "$(rec_chr[end]),$(rec_pos[end]),$(rec_ids[end][end]),$l2normeffect,$pval")
                end
            end
        end
    elseif setlength == 0 #snpset is defined by snpset file
        @warn("This method requires reading in the entire VCF File.
         This can take a lot of memory for large files, as they must be brought into memory.")
        if vcftype == :GT #genotype 
            genomat = convert_gt(Float64, vcffile; 
            model = snpmodel, impute = true, 
            center = false, scale = false)
        else #dosage
            genomat = convert_ds(Float64, vcffile; model = snpmodel,
            key="DS", impute=true, center=false, scale=false)
        end
        SnpArrays.makestream(pvalfile, "w") do io
            test == :score ? println(io, "snpsetid,nsnps,pval") : println(io, 
                "snpsetid,nsnps,l2normeffect,pval")
            for j in eachindex(snpset_ids)
                snpset_id = snpset_ids[j]
                snpinds = findall(snpsetFile[!, :snpset_id] .== snpset_id)
                q = length(snpinds)
                Z = zeros(size(fittednullmodel.mm, 1), q)
                if test == :score
                    ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                    copyto!(ts.Z, @view(genomat[vcfrowinds, snpinds]))
                    pval = polrtest(ts)
                    println(io, "$(snpset_id),$q,$pval")
                elseif test == :lrt
                    γ̂ = Vector{Float64}(undef, q)
                    Xaug = [fittednullmodel.model.X Z]
                    nulldev = deviance(fittednullmodel.model)
                    copyto!(@view(Xaug[:, fittednullmodel.model.p+1:end]), 
                            @view(genomat[vcfrowinds, snpinds]))
                    altmodel = polr(Xaug, fittednullmodel.model.Y, 
                        fittednullmodel.model.link, solver, 
                        wts = fittednullmodel.model.wts)
                    copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                    l2normeffect = norm(γ̂)
                    pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                    println(io, "$(snpset_id),$q,$l2normeffect,$pval")
                end
            end
        end
    else #setlength == -1 (testing just one set with specified snps in snpset)
        @warn("This method requires reading in the entire VCF File.
        This can take a lot of memory for large files, as they must be brought into memory.")
        if vcftype == :GT #genotype 
            genomat = convert_gt(Float64, vcffile; 
            model = snpmodel, impute = true, 
            center = false, scale = false)
        else #dosage
            genomat = convert_ds(Float64, vcffile; model = snpmodel,
            key="DS", impute=true, center=false, scale=false)
        end
        SnpArrays.makestream(pvalfile, "w") do io
            q = length(snpset)
            γ̂ = Vector{Float64}(undef, q)
            Z = zeros(size(fittednullmodel.mm, 1), q)
            if test == :score
                ts = OrdinalMultinomialScoreTest(fittednullmodel.model, Z)
                copyto!(ts.Z, @view(genomat[vcfrowinds, snpset]))
                pval = polrtest(ts)
                println(io, "The joint pvalue of snps indexed",
                    " at $(snpset) is $pval")
            elseif test == :lrt
                nulldev = deviance(fittednullmodel.model)
                Xaug = [fittednullmodel.model.X Z]
                copyto!(@view(Xaug[:, fittednullmodel.model.p+1:end]), 
                        @view(genomat[vcfrowinds, snpset]))
                altmodel = polr(Xaug, fittednullmodel.model.Y, 
                    fittednullmodel.model.link, solver, 
                    wts = fittednullmodel.model.wts)
                copyto!(γ̂, 1, altmodel.β, fittednullmodel.model.p + 1, q)
                l2normeffect = norm(γ̂)
                pval = ccdf(Chisq(q), nulldev - deviance(altmodel))
                println(io, "The l2norm of the effect size vector",
                " is $l2normeffect and joint pvalue of snps indexed", 
                " at $(snpset) is $pval")
            end
        end
    end
    close(reader)
    return fittednullmodel
end


#GxE
#tests selected GxE effects with the snp in the null model. It will be slow so not recommended for all snps.
"""
    ordinalgwasGxE(nullformula, covfile, geneticfile, e)
    ordinalgwasGxE(nullformula, df, geneticfile, e)
    ordinalgwasGxE(fittednullmodel, geneticfile, e)
    ordinalgwasGxE(fittednullmodel, bedfile, bimfile, bedn, e)

# Positional arguments 
- `nullformula::FormulaTerm`: formula for the null model.
- `covfile::AbstractString`: covariate file (csv) with one header line. One column 
    should be the ordinal phenotype coded as integers starting from 1.  For example, 
    ordinal phenotypes can be coded as 1, 2, 3, 4 but not 0, 1, 2, 3.  
- `df::DataFrame`: DataFrame containing response and regressors for null model.
- `geneticfile::AbstractString`: File containing genetic information for GWAS.
    This includes a PLINK file name without the bed, fam, or bim 
    extensions or a VCF file without the .vcf extension. If `geneticfile==nothing`, 
    only null model is fitted. If `geneticfile` is provided, bed, bim, and fam file (or vcf) with 
    same `geneticfile` prefix need to exist. Compressed file formats such as gz and bz2 
    are allowed. Check all allowed formats by `SnpArrays.ALLOWED_FORMAT`. If you're using a VCF file,
    make sure to use the `geneticformat = "VCF"` keyword option, and specificy dosage or genotype data
    with the `vcftype` command.
- `e::Union{AbstractString,Symbol}`: Enviromental variable to be used to test the GxE interaction.
For instance, for testing `sex & snp` interaction, use `:sex` or `"sex"`.
- `fittednullmodel::StatsModels.TableRegressionModel`: the fitted null model 
    output from `ordinalgwas(nullformula, covfile)` or `ordinalgwas(nullformula, df)`.
- `bedfile::Union{AbstractString,IOStream}`: path to Plink bed file with full file name.
- `bimfile::Union{AbstractString,IOStream}`: path to Plink bim file with full file name.
- `bedn::Integer`: number of samples in bed file.

# Keyword arguments
- `geneticformat`::Union{AbstractString}: Type of file used for the genetic analysis. 
`"PLINK"` and `"VCF"` are currently supported. Default is PLINK.
- `vcftype`::Union{Symbol, Nothing}: Data to extract from the VCF file for the GWAS analysis. 
`:DS` for dosage or `:GT` for genotypes. Default is nothing.
- `nullfile::Union{AbstractString, IOStream}`: output file for the fitted null model; 
    default is `ordinalgwas.null.txt`. 
- `pvalfile::Union{AbstractString, IOStream}`: output file for the gwas p-values; default is 
    `ordinalgwas.pval.txt`. 
- `covtype::Vector{DataType}`: type information for `covfile`. This is useful
    when `CSV.read(covarfile)` has parsing errors.  
- `covrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for covariate file.  
- `test::Symbol`: `:score` (default) or `:lrt`.  
- `link::GLM.Link`: `LogitLink()` (default), `ProbitLink()`, `CauchitLink()`,
    or `CloglogLink()`.
- `snpmodel`: `ADDITIVE_MODEL` (default), `DOMINANT_MODEL`, or `RECESSIVE_MODEL`.
- `snpinds::Union{Nothing,AbstractVector{<:Integer}}`: SNP indices for bed/vcf file.
- `geneticrowinds::Union{Nothing,AbstractVector{<:Integer}}`: sample indices for bed/vcf file.
- `solver`: an optimization solver supported by MathProgBase. Default is 
    `NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000)`. Another common choice is 
    `IpoptSolver(print_level=0)`.
- `verbose::Bool`: default is `false`.
"""
function ordinalgwasGxE(
    # positional arguments
    nullformula::FormulaTerm,
    covfile::AbstractString,
    geneticfile::Union{AbstractString},
    e::Union{AbstractString,Symbol};
    # keyword arguments
    covtype::Union{Nothing, Vector{DataType}} = nothing,
    covrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    kwargs...
    )
    covdf = SnpArrays.makestream(covfile) do io
        CSV.read(io, DataFrame; types=covtype)
    end
    e = Symbol(string(e))
    string(e) in names(covdf) || throw(ArgumentError("$e not in covariate file/dataframe"))
    ordinalgwasGxE(nullformula, covrowinds == nothing ? covdf : covdf[covrowinds, :], 
        geneticfile, e; kwargs...)
end

function ordinalgwasGxE(
    nullformula::FormulaTerm,
    covdf::DataFrame,
    geneticfile::Union{AbstractString},
    e::Union{AbstractString,Symbol};
    # keyword arguments
    geneticformat = "PLINK",
    vcftype = nothing,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing, #row indicies to conduct GxE interaction
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwas.pval.txt",
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    geneticrowinds::Union{Nothing, AbstractVector{<:Integer}} = nothing,
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false,
    link::GLM.Link = LogitLink()
    )
    e = Symbol(string(e))
    string(e) in names(covdf) || throw(ArgumentError("$e not in covariate file/dataframe"))
    # locate plink bed, fam, bim files or VCF file
    isplink = occursin("plink", lowercase(geneticformat))
    if isplink
        if isfile(geneticfile * ".bed")
            bedfile = geneticfile * ".bed"
        else
            fmt = findfirst(isfile, geneticfile * ".bed." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("bed file not found"))
            bedfile = geneticfile * ".bed." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        famfile = replace(bedfile, ".bed" => ".fam")
        isfile(famfile) || throw(ArgumentError("fam file not found"))
        bimfile = replace(bedfile, ".bed" => ".bim")
        isfile(bimfile) || throw(ArgumentError("bim file not found"))
        # selected rows should match nobs in null model
        bedn = SnpArrays.makestream(countlines, famfile)
    else
        vcftype in [:GT, :DS] || throw(ArgumentError("vcftype not specified. Allowable types are :GT for genotypes and :DS for dosages."))
        if isfile(geneticfile * ".vcf")
            vcffile = geneticfile * ".vcf"
        else
            fmt = findfirst(isfile, geneticfile * ".vcf." .* SnpArrays.ALLOWED_FORMAT)
            fmt == nothing && throw(ArgumentError("VCF file not found"))
            vcffile = geneticfile * ".vcf." * SnpArrays.ALLOWED_FORMAT[fmt]
        end
        bedn = VCFTools.nsamples(vcffile)
    end
    if geneticrowinds == nothing
        nbedrows = bedn
        rowinds = 1:bedn
    else
        nbedrows = eltype(geneticrowinds) == Bool ? count(geneticrowinds) : length(geneticrowinds)
        rowinds = geneticrowinds
    end
    # fit and output null model and ensure sample size will match
    nm = polr(nullformula, covdf, link, solver)
    nbedrows == nobs(nm) || 
        throw(ArgumentError("number of samples in geneticrowinds does not match null model"))
    # validate testing method
    test = Symbol(lowercase(string(test)))
    test == :score || test == :lrt || throw(ArgumentError("unrecognized test $test"))
    # gwas
    if isplink #plink
        ordinalgwasGxE(nullformula, nm, bedfile, bimfile, bedn, e;
        solver=solver, 
        verbose=verbose,
        snpinds=snpinds,
        test=test,
        snpmodel=snpmodel,
        pvalfile=pvalfile,
        bedrowinds=rowinds)
    else #vcf
        ordinalgwasGxE(nullformula, nm, vcffile, bedn, vcftype, e; 
        solver=solver, 
        verbose=verbose,
        snpinds=snpinds,
        test=test,
        snpmodel=snpmodel,
        pvalfile=pvalfile,
        vcfrowinds=rowinds)
    end
end

# For PLINK Analysis
function ordinalgwasGxE(
    nullformula::FormulaTerm,
    fittednullmodel::StatsModels.TableRegressionModel,
    bedfile::Union{AbstractString, IOStream}, # full path and bed file name
    bimfile::Union{AbstractString, IOStream}, # full path and bim file name
    bedn::Integer,           # number of samples in bed file
    e::Union{AbstractString,Symbol}; #environmental variable for GxE interaction
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwasGxE.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing, #row indicies to conduct GxE interaction
    bedrowinds::AbstractVector{<:Integer} = 1:bedn, # row indices for SnpArray
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    #covdf = fittednullmodel.mf.df
    #covdf[:snp] = zeros(size(covdf, 1))
    Xaug = [fittednullmodel.model.X zeros(size(fittednullmodel.mm, 1))]
    Xaug2 = [fittednullmodel.model.X zeros(size(fittednullmodel.mm, 1), 2)] #or get Xaug to point to part of it
    # create SnpArray
    genomat = SnpArrays.SnpArray(bedfile, bedn)
    cc = SnpArrays.counts(genomat, dims=1) 
    mafs = SnpArrays.maf(genomat)
    envvar = DataFrame(fittednullmodel.mf.data)[!, e]
    testvec = zeros(size(fittednullmodel.mm, 1), 1)
    # create SNP mask vector
    if snpinds == nothing
        snpmask = trues(SnpArrays.makestream(countlines, bimfile))
    elseif eltype(snpinds) == Bool
        snpmask = snpinds
    else
        snpmask = falses(SnpArrays.makestream(countlines, bimfile))
        snpmask[snpinds] .= true
    end
    snpeffectnull = 0.0
    if test == :score
        SnpArrays.makestream(pvalfile, "w") do io
            println(io, "chr,pos,snpid,maf,hwepval,snpeffectnull,pval")
            SnpArrays.makestream(bimfile) do bimio
                for j in eachindex(snpmask)
                    row = readline(bimio)
                    snpmask[j] || continue
                    hwepval = SnpArrays.hwe(cc[1, j], cc[3, j], cc[4, j])
                    maf = mafs[j]
                    if maf == 0 # mono-allelic
                        pval = 1.0
                        snpeffectnull = 0.0
                    else
                        copyto!(@view(Xaug[:, end]), @view(genomat[bedrowinds,
                        j]), impute=true, model=snpmodel)
                        copyto!(testvec, @view(Xaug[:, end]) .* envvar)
                        nm = polr(Xaug, fittednullmodel.model.Y, 
                            fittednullmodel.model.link, solver, wts = fittednullmodel.model.wts)
                        snpeffectnull = nm.β[end]
                        ts = OrdinalMultinomialScoreTest(nm, testvec)
                        pval = polrtest(ts)
                    end
                    snpj = split(row)
                    println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$maf,$hwepval,$snpeffectnull,$pval")
                end
            end
        end
    elseif test == :lrt
        γ̂ = 0.0 # effect size for columns being tested
        SnpArrays.makestream(pvalfile, "w") do io
            println(io, "chr,pos,snpid,maf,hwepval,snpeffectnull,snpeffectfull,GxEeffect,pval")
            SnpArrays.makestream(bimfile) do bimio
                for j in eachindex(snpmask)
                    row = readline(bimio)
                    snpmask[j] || continue
                    hwepval = SnpArrays.hwe(cc[1, j], cc[3, j], cc[4, j])
                    maf = mafs[j]
                    if maf == 0 # mono-allelic
                        γ̂ = 0.0
                        pval = 1.0
                        snpeffectfull = 0.0
                        snpeffectnull = 0.0
                    else
                        copyto!(@view(Xaug[:, end]), @view(genomat[bedrowinds,
                            j]), impute=true, model=snpmodel)
                        copyto!(@view(Xaug2[:, end - 1]), @view(Xaug[:, end]))
                        copyto!(@view(Xaug2[:, end]), @view(Xaug[:, end]) .*
                            envvar)
                        nm = polr(Xaug, fittednullmodel.model.Y, 
                        fittednullmodel.model.link, solver, wts = fittednullmodel.model.wts)
                        snpeffectnull = nm.β[end]
                        nulldev = deviance(nm)
                        altmodel = polr(Xaug2, fittednullmodel.model.Y, 
                            fittednullmodel.model.link, solver, 
                            wts = fittednullmodel.model.wts)
                        γ̂ = altmodel.β[end]
                        snpeffectfull = altmodel.β[end-1]
                        pval = ccdf(Chisq(1), nulldev - deviance(altmodel))
                    end
                    snpj = split(row)
                    println(io, "$(snpj[1]),$(snpj[4]),$(snpj[2]),$maf,",
                        "$hwepval,$snpeffectnull,$snpeffectfull,$γ̂,$pval")
                end
            end
        end
    end
    return fittednullmodel
end

# For VCF Analysis
function ordinalgwasGxE(
    nullformula::FormulaTerm,
    fittednullmodel::StatsModels.TableRegressionModel,
    vcffile::Union{AbstractString, IOStream}, # full path and bed file name
    nsamples::Integer,           # number of samples in bed file
    vcftype::Symbol,        # :GT for genotype, :DS for dosages
    e::Union{AbstractString,Symbol}; #environmental variable for GxE interaction
    test::Symbol = :score,
    pvalfile::Union{AbstractString, IOStream} = "ordinalgwasGxE.pval.txt", 
    snpmodel::Union{Val{1}, Val{2}, Val{3}} = ADDITIVE_MODEL,
    snpinds::Union{Nothing, AbstractVector{<:Integer}} = nothing, #row indicies to conduct GxE interaction
    vcfrowinds::AbstractVector{<:Integer} = 1:nsamples, # row indices for SnpArray
    solver = NLoptSolver(algorithm=:LD_SLSQP, maxeval=4000),
    verbose::Bool = false
    )
    # get number of SNPs in file
    nsnps = nrecords(vcffile)

    # for VCFTools, snpmodel is coded differently 
    snpmodel = modelingdict[snpmodel]

    # create holders for chromome, position, id 
    rec_chr = Array{Any, 1}(undef, 1)
    rec_pos = Array{Any, 1}(undef, 1)
    rec_ids = Array{Any, 1}(undef, 1)
    gholder = zeros(Union{Missing, Float64}, nsamples)

    # create SNP mask vector
    if snpinds == nothing
        snpmask = trues(nsnps)
    elseif eltype(snpinds) == Bool
        snpmask = snpinds
    else
        snpmask = falses(nsnps)
        snpmask[snpinds] .= true
    end

    Xaug = [fittednullmodel.model.X zeros(size(fittednullmodel.mm, 1))]
    Xaug2 = [fittednullmodel.model.X zeros(size(fittednullmodel.mm, 1), 2)] #or get Xaug to point to part of it

    # create array for environmental variable and testing 
    envvar = DataFrame(fittednullmodel.mf.data)[!, e]
    testvec = zeros(size(fittednullmodel.mm, 1), 1)

    snpeffectnull = 0.0
    reader = VCF.Reader(openvcf(vcffile))

    SnpArrays.makestream(pvalfile, "w") do io
        if test == :score 
            println(io, "chr,pos,snpid,snpeffectnull,pval")
        else 
            println(io, "chr,pos,snpid,snpeffectnull,snpeffectfull,GxEeffect,pval")
        end
        for j in eachindex(snpmask)
            if !snpmask[j] #skip snp, must read marker still. 
                copy_gt!(gholder, reader; model = snpmodel, impute = true,
                record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
                continue
            end
            if vcftype == :GT #genotype 
                copy_gt!(gholder, reader; model = snpmodel, impute = true,
                record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
            else #dosage
                copy_ds!(gholder, reader; model = snpmodel, impute = true,
                record_chr = rec_chr, record_pos = rec_pos, record_ids = rec_ids)
            end
            copyto!(@view(Xaug[:, end]), @view(gholder[vcfrowinds]))

            if test == :score
                copyto!(testvec, @view(Xaug[:, end]) .* envvar)
                nm = polr(Xaug, fittednullmodel.model.Y, 
                    fittednullmodel.model.link, solver, wts = fittednullmodel.model.wts)
                snpeffectnull = nm.β[end]
                ts = OrdinalMultinomialScoreTest(nm, testvec)
                pval = polrtest(ts)
                println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),$snpeffectnull,$pval")
            elseif test == :lrt
                γ̂ = 0.0 # effect size for columns being tested
                copyto!(@view(Xaug2[:, end - 1]), @view(Xaug[:, end]))
                copyto!(@view(Xaug2[:, end]), @view(Xaug[:, end]) .*
                    envvar)
                nm = polr(Xaug, fittednullmodel.model.Y, 
                fittednullmodel.model.link, solver, wts = fittednullmodel.model.wts)
                snpeffectnull = nm.β[end]
                nulldev = deviance(nm)
                altmodel = polr(Xaug2, fittednullmodel.model.Y, 
                    fittednullmodel.model.link, solver, 
                    wts = fittednullmodel.model.wts)
                γ̂ = altmodel.β[end]
                snpeffectfull = altmodel.β[end-1]
                pval = ccdf(Chisq(1), nulldev - deviance(altmodel))
                println(io, "$(rec_chr[1]),$(rec_pos[1]),$(rec_ids[1][1]),",
                    "$snpeffectnull,$snpeffectfull,$γ̂,$pval")
            end
        end
    end
    close(reader)
    return fittednullmodel
end

#for VCF they use different coding for additive, dominant, recessive models 
modelingdict = Dict(Val{1}() => :additive,
Val{2}() => :dominant,
Val{3}() => :recessive)