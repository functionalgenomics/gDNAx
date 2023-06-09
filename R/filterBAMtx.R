#' Filter alignments in a BAM file using a transcriptome
#'
#' Filter alignments in a BAM file using criteria based on a
#' transcriptome annotation.
#'
#' @param object gDNAx object obtained with the function 'gDNAdx()'.
#'
#' @param path Directory where to write the output BAM files.
#'
#' @param txflag A value from a call to the function 'filterBAMtxFlag()'.
#'
#' @param param A 'ScanBamParam' object.
#'
#' @param yieldSize (Default 1e6) Number of records in the input BAM file to
#' yield each time the file is read. The lower the value, the smaller memory
#' consumption, but in the case of large BAM files, values below 1e6 records
#' may decrease the overall performance.
#'
#' @param verbose (Default TRUE) Logical value indicating if progress should be
#' reported through the execution of the code.
#'
#' @param BPPARAM An object of a \linkS4class{BiocParallelParam} subclass
#' to configure the parallel execution of the code. By default, a
#' \linkS4class{SerialParam} object is used, which does not use any
#' parallelization, with the flag \code{progress=TRUE} to show progress
#' through the calculations.
#'
#' @return A vector of output filename paths.
#' 
#' @examples
#' \donttest{
#' library(gDNAinRNAseqData)
#' 
#' library(TxDb.Hsapiens.UCSC.hg38.knownGene)
#' txdb <- TxDb.Hsapiens.UCSC.hg38.knownGene
#' 
#' # Retrieving BAM files
#' bamfiles <- LiYu22subsetBAMfiles()
#' 
#' # Getting information about the gDNA concentrations of each BAM file
#' pdat <- LiYu22phenoData(bamfiles)
#' 
#' gdnax <- gDNAdx(bamfiles, txdb, singleEnd=FALSE, strandMode=NA)
#' 
#' # Filtering splice-compatible alignments and writing them into new BAM files
#' fbf <- filterBAMtxFlag(isSpliceCompatibleJunction=TRUE,
#'                        isSpliceCompatibleExonic=TRUE)
#' fstats <- filterBAMtx(gdnax, path=".", txflag=fbf)
#' list.files(".", pattern="*.bam$")
#' }
#' 
#'
#' @importFrom S4Vectors mcols
#' @importFrom Rsamtools BamFileList scanBamFlag ScanBamParam
#' @importFrom Rsamtools bamWhat bamWhat<-
#' @importFrom GenomicFeatures exonsBy
#' @importFrom GenomeInfoDb keepStandardChromosomes
#' @importFrom BiocParallel SerialParam bplapply bpnworkers
#' @export
#' @rdname filterBAMtx
filterBAMtx <- function(object, path=".", txflag=filterBAMtxFlag(),
                        param=ScanBamParam(), yieldSize=1000000, verbose=TRUE,
                        BPPARAM=SerialParam(progressbar=verbose)) {

    bfl <- object@bfl
    singleEnd <- object@singleEnd
    strandMode <- object@strandMode
    stdChrom <- object@stdChrom
    igc <- object@intergenic
    int <- object@intronic
    tx <- object@transcripts
    tx2gene <- object@tx2gene

    # if (is.na(strandMode))
    #     strandMode <- 1L
    
    if (!file.exists(path))
        stop(sprintf("path %s does not exist.", path))

    if (txflag == 0)
        stop(paste("No alignment type selected in argument 'txflag'. Please",
                    "use the function 'filterBAMtxFlag()' to select at least",
                    "one.", sep=" "))

    yieldSize <- .checkYieldSize(yieldSize)
    bfl <- lapply(bfl, function(x, ys) {
                            yieldSize(x) <- ys
                            x
                        }, yieldSize)

    flag0 <- scanBamFlag(isUnmappedQuery=FALSE)
    what0 <- c("rname", "strand", "pos", "cigar", "qname")
    if (singleEnd)
        bamWhat(param) <- setdiff(bamWhat(param),
                                    c("groupid", "mate_status"))
    else {
        flag0 <- scanBamFlag(isPaired=TRUE, hasUnmappedMate=FALSE,
                             isUnmappedQuery=FALSE)
        what0 <- c(what0, "flag", "groupid", "mate_status")
    }
    param <- GenomicAlignments:::.normargParam(param, flag0, what0)

    if (verbose)
        message("Start processing BAM file(s)")

    out.stats <- NULL
    if (length(bfl) > 1 && bpnworkers(BPPARAM) > 1) {
        verbose <- FALSE
        out.stats <- bplapply(bfl, .filter_oneBAMtx, igc=igc, int=int, tx=tx,
                            path=path, txflag=txflag, singleEnd=singleEnd,
                            strandMode=strandMode, stdChrom=stdChrom,
                            tx2gene=tx2gene, param=param, verbose=verbose,
                            BPPARAM=BPPARAM)
    } else
        out.stats <- lapply(bfl, .filter_oneBAMtx, igc=igc, int=int, tx=tx,
                            path=path, txflag=txflag, singleEnd=singleEnd,
                            strandMode=strandMode, stdChrom=stdChrom,
                            tx2gene=tx2gene, param=param, verbose=verbose)

    out.stats <- data.frame(do.call("rbind", out.stats))
    out.stats
}

#' @importFrom BiocGenerics basename path
#' @importFrom S4Vectors FilterRules
#' @importFrom Rsamtools filterBam
.filter_oneBAMtx <- function(bf, igc, int, tx, path, txflag, singleEnd,
                            strandMode, stdChrom, tx2gene, param, verbose) {

    onesuffix <- c(isIntergenic="IGC",
                    isIntronic="INT",
                    isSpliceCompatibleJunction="SCJ",
                    isSpliceCompatibleExonic="SCE")
    suffix <- "_"
    for (flag in TXFLAG_BITNAMES)
        if (testBAMtxFlag(txflag, flag))
            suffix <- paste0(suffix, onesuffix[flag])

    bamoutfile <- sprintf("%s/%s.bam", path,
                        paste0(gsub(".bam", "", basename(path(bf))), suffix))
    baioutfile <- sprintf("%s/%s.bai", path,
                        paste0(gsub(".bam", "", basename(path(bf))), suffix))
    statsenvname <- sprintf("stats_%s", gsub(".bam", "", basename(path(bf))))
    assign(statsenvname, new.env())
    assign("stats", c(NALN=0L, NIGC=0L, NINT=0L, NSCJ=0L, NSCE=0L),
            envir=get(statsenvname))

    if (verbose)
        message(sprintf("Processing %s", basename(path(bf))))
    filter <- FilterRules(list(BAMtx=.bamtx_filter))
    ff <- filterBam(bf, tempfile(), param=param, filter=filter,
                    indexDestination=TRUE)
    file.copy(ff, bamoutfile)
    file.remove(ff)
    file.copy(paste0(ff, ".bai"), baioutfile)
    file.remove(paste0(ff, ".bai"))
    stats <- get("stats", envir=get(statsenvname))
    for (flag in TXFLAG_BITNAMES)
        if (!testBAMtxFlag(txflag, flag))
            stats[paste0("N", onesuffix[flag])] <- NA_integer_
    stats
}

#' @importFrom Rsamtools bamWhat bamTag
#' @importFrom S4Vectors DataFrame mcols<-
#' @importFrom GenomeInfoDb seqlengths
#' @importFrom GenomicAlignments GAlignments njunc first
.bamtx_filter <- function(x) {
    n <- 5  ## this number is derived from the fact that .scj_filter()
            ## is called by 'eval()' within the 'filterBam()' function
            ## and allows one to access the objects in the scope of
            ## .filter_oneBAMtx() through the environment 'parent.frame(n)'
    bf <- get("bf", envir=parent.frame(n))
    param <- get("param", envir=parent.frame(n))
    txflag <- get("txflag", envir=parent.frame(n))
    singleEnd <- get("singleEnd", envir=parent.frame(n))
    strandMode <- get("strandMode", envir=parent.frame(n))
    stdChrom <- get("stdChrom", envir=parent.frame(n))
    igc <- get("igc", envir=parent.frame(n))
    int <- get("int", envir=parent.frame(n))
    tx <- get("tx", envir=parent.frame(n))
    tx2gene <- get("tx2gene", envir=parent.frame(n))
    verbose <- get("verbose", envir=parent.frame(n))
    statsenvname <- get("statsenvname", envir=parent.frame(n))
    statsenv <- get(statsenvname, envir=parent.frame(n))
    seqlengths <- seqlengths(bf)
    if (!is.null(seqlengths)) {
        bad <- setdiff(levels(x$rname), names(seqlengths))
        if (length(bad) > 0) {
            bad <- paste(bad, collapse="' '")
            msg <- sprintf(paste("'rname' lengths not in BamFile header;",
                                "seqlengths not used\n  file: %s\n  missing",
                                "rname(s): '%s'", sep=" "), path(bf), bad)
            warning(msg)
            seqlengths <- NULL
        }
    }
    gal <- GAlignments(seqnames=x$rname, pos=x$pos,
                        cigar=x$cigar, strand=x$strand,
                        seqlengths=seqlengths)
    stopifnot(nrow(x) == length(gal)) ## QC
    cnames <- setdiff(c(bamWhat(param), bamTag(param)),
                        c("rname", "pos", "cigar", "strand"))
    if (length(cnames) > 0) {
        dtf <- do.call(DataFrame, as.list(x[cnames]))
        colnames(dtf) <- cnames
        mcols(gal) <- dtf
    }
    if (!singleEnd) {
        use.mcols <- setdiff(c(bamWhat(param), bamTag(param)),
                            c("rname", "pos", "cigar", "strand"))
        strandMode2 <- strandMode
        if (is.na(strandMode))
            strandMode2 <- 1L
        makeGALP <- GenomicAlignments:::.make_GAlignmentPairs_from_GAlignments
        gal <- makeGALP(gal, strandMode2, use.mcols=use.mcols)
    }
    if (stdChrom)
        gal <- keepStandardChromosomes(gal, pruning.mode="fine")
    gal <- .matchSeqinfo(gal, tx, verbose)
    mask <- rep(FALSE, length(gal))
    whalnstr <- character(0)
    stats <- c(NALN=length(gal), NIGC=0L, NINT=0L, NSCJ=0L, NSCE=0L)
    if (testBAMtxFlag(txflag, "isIntergenic")) {
        igcaln <- .igcAlignments(gal, igc, fragmentsLen=FALSE)
        mask <- mask | igcaln$igcmask
        whalnstr <- c(whalnstr, "IGC")
        stats["NIGC"] <- sum(igcaln$igcmask)
    }
    if (testBAMtxFlag(txflag, "isIntronic")) {
        intaln <- .intAlignments(gal, int, strandMode, fragmentsLen=FALSE)
        mask <- mask | intaln$intmask
        whalnstr <- c(whalnstr, "INT")
        stats["NINT"] <- sum(intaln$intmask)
    }
    if (testBAMtxFlag(txflag, "isSpliceCompatibleJunction") ||
        testBAMtxFlag(txflag, "isSpliceCompatibleExonic")) {
        scoaln <- .scoAlignments(gal, tx, tx2gene, singleEnd, strandMode,
                                fragmentsLen=FALSE)
        if (testBAMtxFlag(txflag, "isSpliceCompatibleJunction")) {
            mask <- mask | scoaln$scjmask
            whalnstr <- c(whalnstr, "SCJ")
            stats["NSCJ"] <- sum(scoaln$scjmask)
        }
        if (testBAMtxFlag(txflag, "isSpliceCompatibleExonic")) {
            mask <- mask | scoaln$scemask
            whalnstr <- c(whalnstr, "SCE")
            stats["NSCE"] <- sum(scoaln$scemask)
        }
    }
    envstats <- get("stats", envir=statsenv)
    envstats <- envstats + stats
    assign("stats", envstats, envir=statsenv)

    if (verbose)
        message(sprintf("%d alignments processed, %d (%.2f%%) %s written",
                        envstats["NALN"], sum(envstats[-1]),
                        100*sum(envstats[-1])/envstats["NALN"],
                        paste(whalnstr, collapse=", ")))

    mt <- match(x$qname, mcols(first(gal))$qname)
    mask <- mask[mt]

    mask
}

TXFLAG_BITNAMES <- c("isIntergenic",
                    "isIntronic",
                    "isSpliceCompatibleJunction",
                    "isSpliceCompatibleExonic")

## adapted from Rsamtools::scanBamFlag()

#' Transcriptome-based parameters for filtering BAM files
#'
#' Use 'filterBAMtxFlag()' to set what types of alignment in a BAM 
#' file should be filtered using the function 'filterBAMtx()',
#' among being splice-compatible with one or more junctions,
#' splice-compatible exonic, intronic or intergenic.
#' 
#' @param isSpliceCompatibleJunction (Default FALSE) Logical value indicating
#'        if spliced alignments overlapping a transcript in a 
#'        "splice compatible" way should be included in the BAM file. For
#'        paired-end reads, one or both alignments must have one or more splice
#'        site(s) compatible with splicing. See 
#'        \code{\link[GenomicAlignments:OverlapEncodings-class]{OverlapEncodings}}.
#' 
#' @param isSpliceCompatibleExonic (Default FALSE) Logical value indicating
#'        if alignments without a splice site, but that overlap a transcript
#'        in a "splice compatible" way, should be included in the BAM file.
#'        For paired-end reads, none of the alignments must be spliced, and
#'        each pair can be in different exons (or in the same one), as long as
#'        they are "splice compatible". See 
#'        \code{\link[GenomicAlignments:OverlapEncodings-class]{OverlapEncodings}}.
#'        
#' @param isIntronic (Default FALSE) Logical value indicating if alignments
#'        mapping to introns should be included in the BAM file.
#'
#' @param isIntergenic (Default FALSE) Logical value indicating if alignments
#'        aligned to intergenic regions should be included in the BAM file.
#'
#'
#' @examples
#' library(gDNAinRNAseqData)
#' 
#' library(TxDb.Hsapiens.UCSC.hg38.knownGene)
#' txdb <- TxDb.Hsapiens.UCSC.hg38.knownGene
#' 
#' # Retrieving BAM files
#' bamfiles <- LiYu22subsetBAMfiles()
#' 
#' # Getting information about the gDNA concentrations of each BAM file
#' pdat <- LiYu22phenoData(bamfiles)
#' 
#' gdnax <- gDNAdx(bamfiles, txdb, singleEnd=FALSE, strandMode=NA)
#' 
#' # Filtering splice-compatible alignments and writing them into new BAM files
#' fbf <- filterBAMtxFlag(isSpliceCompatibleJunction=TRUE,
#'                        isSpliceCompatibleExonic=TRUE)
#' 
#' @export
#' @rdname filterBAMtx
filterBAMtxFlag <- function(isSpliceCompatibleJunction=FALSE,
                            isSpliceCompatibleExonic=FALSE,
                            isIntronic=FALSE,
                            isIntergenic=FALSE) {
    flag <- S4Vectors:::makePowersOfTwo(length(TXFLAG_BITNAMES))
    names(flag) <- TXFLAG_BITNAMES
    args <- lapply(as.list(match.call())[-1], eval, parent.frame())
    if (any(vapply(args, length, FUN.VALUE = integer(1L)) > 1L))               
        stop("all arguments must be logical(1)")

    if (length(args) == 0)
        args <- formals(filterBAMtxFlag)

    idx <- names(args[sapply(args, function(x) !is.na(x) && x)])
    keep <- Reduce("+", flag[names(flag) %in% idx], 0L)

    keep
}


#' @param flag A value from a call to the function 'filterBAMtxFlag()'.
#' 
#' @param value A character vector with the name of a flag.
#' 
#' @importFrom bitops bitAnd
#'
#' @export
#' @rdname filterBAMtx
testBAMtxFlag <- function(flag, value) {
    if (length(value) != 1 || !value %in% TXFLAG_BITNAMES) {
        msg <- sprintf("'is' must be character(1) in '%s'",
                        paste(TXFLAG_BITNAMES, collapse="' '"))
        stop(msg)
    }
    i <- 2 ^ (match(value, TXFLAG_BITNAMES) - 1L)
    bitAnd(flag, i) == i
}
