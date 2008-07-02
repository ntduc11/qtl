######################################################################
# stepwiseqtl.R
#
# copyright (c) 2007-8, Karl W Broman
# 
# last modified Jul, 2008
# first written Nov, 2007
# Licensed under the GNU General Public License version 2 (June, 1991)
# 
# Part of the R/qtl package
# Contains: stepwiseqtl, calc.plod, countqtlterms, calc.penalties,
#           checkStepwiseqtlStart
#
######################################################################

######################################################################
# stepwiseqtl
#
# perform forward and backward selection to identify multiple QTL
#
# cross:        cross object
# chr:          chromosomes to consider
# pheno.col:    phenotype column
# qtl           (Optional) If given, qtl object used at start of
#               forward selection.  If missing, we start at the null
#               model.
# formula       If given, formula used with the qtl object for the model
#               at the start of forward selection
# max.qtl:      maximum no. QTL in forward selection
# covar:        data.frame with covariates (strictly additive at this point)
# method:       imputation or Haley-Knott regression
# incl.markers: If TRUE, include marker positions in scan; if FALSE,
#               just use the grid
# refine.locations:  If TRUE, refine the QTL positions at each step
# additive.only: If TRUE, don't scan for interactions
# scan.pairs:    If TRUE, do a pairscan at each step
# penalties:     Vector with 3 values: the penalties on main effects
#                followed by the heavy and light interaction penalties.
#                (if missing, we use default values derived via
#                simulation)
# keeplodprofile If TRUE, perform one last pass of refineqtl and save
#                the LOD profiles.
# keeptrace      If TRUE, retain the QTL locations, model formula and pLOD 
#                for the best model from each step of forward and backward
#                selection as an attribute in the output
# verbose:    If TRUE, print a bunch of tracing information
######################################################################
stepwiseqtl <-
function(cross, chr, pheno.col=1, qtl, formula, max.qtl=10, covar=NULL,
         method=c("imp", "hk"), incl.markers=TRUE, refine.locations=TRUE,
         additive.only=FALSE, scan.pairs=FALSE, penalties,
         keeplodprofile=FALSE, keeptrace=FALSE, verbose=TRUE)
{
  if(!any(class(cross) == "cross")) 
    stop("Input should have class \"cross\".")

  if(!missing(chr)) cross <- subset(cross, chr)

  if(LikePheVector(pheno.col, nind(cross), nphe(cross))) {
    cross$pheno <- cbind(pheno.col, cross$pheno)
    pheno.col <- 1
  }

  if(!missing(qtl)) { # start f.s. at somewhere other than the null
    # check that chromosomes were retained, otherwise give error
    m <- is.na(match(qtl$chr, names(cross$geno)))
    if(any(m)) {
      wh <- qtl$chr[m]
      if(length(wh) > 1)
        stop("Chromosomes ", paste(wh, collapse=", "), " (in QTL object) not in cross object.")
      else
        stop("Chromosome ", wh, " (in QTL object) not in cross object.")
    }
    if(missing(formula)) { # create a formula with all covariates and all QTL add've
      if(!is.null(covar)) 
        formula <- paste("y ~ ", paste(names(covar), collapse="+"), "+")
      else
        formula <- "y ~ "
      formula <- paste(formula, paste(paste("Q", 1:length(qtl$chr), sep=""), collapse="+"))
    }
    else {
      temp <- checkStepwiseqtlStart(qtl, formula, covar)
      qtl <- temp$qtl
      formula <- temp$formula
    }
    startatnull <- FALSE
  }
  else {
    if(!missing(formula)) 
      warning("formula ignored if qtl is not provided.")
    startatnull <- TRUE
  }

  # revise names in qtl object
  if(!startatnull) 
    qtl$name <- qtl$altname

  # check that we have the right stuff for the selected method
  method <- match.arg(method)
  if(method=="imp") {
    if(!("draws" %in% names(cross$geno[[1]]))) {
      if("prob" %in% names(cross$geno[[1]])) {
        warning("The cross doesn't contain imputations; using method=\"hk\".")
        method <- "hk"
      }
      else
        stop("You need to first run sim.geno.")
    }
  }
  else {
    if(!("prob" %in% names(cross$geno[[1]]))) {
      if("draws" %in% names(cross$geno[[1]])) {
        warning("The cross doesn't contain QTL genotype probabilities; using method=\"imp\".")
        method <- "imp"
      }
      else
        stop("You need to first run calc.genoprob.")
    }
  }
  if(method=="imp") qtlmethod <- "draws"
  else qtlmethod <- "prob"

  # check that qtl object matches the method
  if(!startatnull) {
    if(method=="imp" && !("geno" %in% names(qtl)))
      stop("The qtl object doesn't contain imputations; re-run makeqtl with what=\"draws\".")
    else if(method=="hk" && !("prob" %in% names(qtl))) 
      stop("The qtl object doesn't contain QTL genotype probabilities; re-run makeqtl with what=\"prob\".")
  }
    
  # check phenotypes and covariates; drop ind'ls with missing values
  if(length(pheno.col) > 1) {
    pheno.col <- pheno.col[1]
    warning("scanqtl can take just one phenotype; only the first will be used")
  }
  if(is.character(pheno.col)) {
    num <- find.pheno(cross, pheno.col)
    if(is.na(num)) 
      stop("Couldn't identify phenotype \"", pheno.col, "\"")
    pheno.col <- num
  }
  if(any(pheno.col < 1 | pheno.col > nphe(cross)))
    stop("pheno.col values should be between 1 and the no. phenotypes")
  pheno <- cross$pheno[,pheno.col]
  if(!is.null(covar)) phcovar <- cbind(pheno, covar)
  else phcovar <- as.data.frame(pheno)
  hasmissing <- apply(phcovar, 1, function(a) any(is.na(a)))
  if(all(hasmissing))
    stop("All individuals are missing phenotypes or covariates.")
  if(any(hasmissing)) {
    pheno <- pheno[!hasmissing]
    cross <- subset(cross, ind=!hasmissing)
    if(!is.null(covar)) covar <- covar[!hasmissing,,drop=FALSE]

    if(!startatnull) {
      if(method=="imp") 
        qtl$geno <- qtl$geno[!hasmissing,,,drop=FALSE]
      else {
        for(i in seq(along=qtl$prob))
          qtl$prob[[i]] <- qtl$prob[[i]][!hasmissing,,drop=FALSE]
      }
      qtl$n.ind <- sum(!hasmissing)
    }
  }

  if(max.qtl < 1)
    stop("Need max.qtl > 0 if we are to scan for qtl")

  if(is.null(covar)) {
    lod0 <- 0
    if(startatnull)
      firstformula <- y~Q1
    else firstformula <- formula
  }
  else {
    lod0 <- length(pheno)/2 * log10(sum((pheno-mean(pheno))^2) / sum(lm(pheno ~ as.matrix(covar))$resid^2))
    if(startatnull)
      firstformula <- as.formula(paste("y~", paste(names(covar), collapse="+"), "+", "Q1"))
    else firstformula <- formula
  }
    

  # penalties
  cross.type <- class(cross)[1]
  if(missing(penalties)) {
    if(cross.type=="f2") {
      penalties <-  c(3.52, 4.28, 2.69)
    }
    else if(cross.type=="bc") {
      penalties <-  c(2.69, 2.62, 1.19)
    }
    else 
      stop("No default penalties available for cross type ", cross.type)
  }
  else if(length(penalties) != 3) {
    if(length(penalties)==2) 
      penalties <- penalties[c(1,2,2)]
    else {
      warning("penalties should have length 3")
      penalties <- penalties[1:3]
    }
  }

  if(verbose > 2) verbose.scan <- TRUE
  else verbose.scan <- FALSE

  curbest <- NULL
  curbestplod <- 0

  # initial scan : either 1d or 2d
  if(verbose) cat(" -Initial scan\n")
  if(startatnull) {
    if(additive.only || max.qtl == 1 || !scan.pairs) {
      out <- scanone(cross, pheno.col=pheno.col, method=method, model="normal",
                     addcovar=covar)
      lod <- max(out[,3], na.rm=TRUE)
      
      curplod <- calc.plod(lod, c(1,0,0), penalties=penalties)
      wh <- which(!is.na(out[,3]) & out[,3]==lod)
      if(length(wh) > 1) wh <- sample(wh, 1)
      
      qtl <- makeqtl(cross, as.character(out[wh,1]), out[wh,2], "Q1",
                     what=qtlmethod)
      formula <- firstformula
      n.qtl <- 1
    }
    else {
      out <- scantwo(cross, pheno.col=pheno.col, method=method, model="normal",
                     incl.markers=incl.markers, addcovar=covar, verbose=verbose.scan)
      lod <- out$lod
      
      lod1 <- max(diag(lod), na.rm=TRUE)
      plod1 <- calc.plod(lod1, c(1,0,0), penalties=penalties)
      loda <- max(lod[upper.tri(lod)], na.rm=TRUE)
      ploda <- calc.plod(loda, c(2,0,0),
                         penalties=penalties)
      lodf <- max(lod[lower.tri(lod)], na.rm=TRUE)
      plodf <- calc.plod(lodf, c(2,0,1),
                         penalties=penalties)

      if(plod1 > ploda && plod1 > plodf) {
        wh <- which(!is.na(diag(lod)) & diag(lod) == lod1)
        if(length(wh) > 1) wh <- sample(wh, 1)
        m <- out$map[wh,]
        qtl <- makeqtl(cross, as.character(m[1,1]), m[1,2], "Q1", what=qtlmethod)
        formula <- firstformula
        n.qtl <- 1
        lod <- lod1
        curplod <- plod1
      }
      else if(ploda > plodf) {
        temp <- max(out, what="add")
        if(nrow(temp) > 1)
          temp <- temp[sample(1:nrow(temp),1),]
        qtl <- makeqtl(cross, c(as.character(temp[1,1]), as.character(temp[1,2])),
                       c(temp[1,3], temp[1,4]), c("Q1","Q2"), what=qtlmethod)
        formula <- as.formula(paste(deparseQTLformula(firstformula), "+Q2", sep=""))
        curplod <- ploda
        lod <- loda
        n.qtl <- 2
      }
      else {
        temp <- max(out, what="full")
        if(nrow(temp) > 1)
          temp <- temp[sample(1:nrow(temp),1),]
        qtl <- makeqtl(cross, c(as.character(temp[1,1]), as.character(temp[1,2])),
                       c(temp[1,3], temp[1,4]), c("Q1","Q2"), what=qtlmethod)
        formula <- as.formula(paste(deparseQTLformula(firstformula), "+Q2+Q1:Q2", sep=""))
        curplod <- plodf
        lod <- lodf
        n.qtl <- 2
      }
    }
  } # start at null
  else {
    cat(" ---Starting at a model with", length(qtl$chr), "QTL\n")
    if(refine.locations) {
      if(verbose) cat(" ---Refining positions\n")
      rqtl <- refineqtl(cross, pheno.col=pheno.col, qtl=qtl,
                        covar=covar, formula=formula, method=method,
                        verbose=verbose.scan, incl.markers=incl.markers,
                        keeplodprofile=FALSE)
      if(any(rqtl$pos != qtl$pos)) { # updated positions
        if(verbose) cat(" ---  Moved a bit\n")
      }
      qtl <- rqtl
    }
    lod <- fitqtl(cross, pheno.col, qtl, covar=covar, formula=formula,
                  method=method, dropone=FALSE, get.ests=FALSE,
                  run.checks=FALSE)$result.full[1,4] - lod0
    curplod <- calc.plod(lod, countqtlterms(formula, ignore.covar=TRUE),
                         penalties=penalties)
    attr(qtl, "pLOD") <- curplod
    n.qtl <- length(qtl$chr)
  }
 
  attr(qtl, "formula") <- deparseQTLformula(formula)
  attr(qtl, "pLOD") <- curplod

  if(curplod > 0) {
    curbest <- qtl
    curbestplod <- curplod

    if(verbose) 
      cat("** new best ** (pLOD increased by ", round(curplod, 4), ")\n", sep="")
  }

  if(keeptrace) {
    temp <- list(chr=qtl$chr, pos=qtl$pos)
    attr(temp, "formula") <- deparseQTLformula(formula)
    attr(temp, "pLOD") <- curplod
    class(temp) <- c("compactqtl", "list")
    thetrace <- list("0"=temp)
  }

  if(verbose)
    cat("    no.qtl = ", n.qtl, "  pLOD =", curplod, "  formula:",
        deparseQTLformula(formula), "\n")
  if(verbose > 1) 
    cat("         qtl:", paste(qtl$chr, round(qtl$pos,1), sep=":"), "\n")

  # start stepwise search
  i <- 0
  while(n.qtl < max.qtl) {
    i <- i+1
    
    if(verbose) {
      cat(" -Step", i, "\n")
      cat(" ---Scanning for additive qtl\n")
    }

    out <- addqtl(cross, pheno.col=pheno.col, qtl=qtl, covar=covar,
                  formula=formula, method=method, incl.markers=incl.markers,
                  verbose=verbose.scan)
    
    curlod <- max(out[,3], na.rm=TRUE) 
    wh <- which(!is.na(out[,3]) & out[,3]==curlod)
    if(length(wh) > 1) wh <- sample(wh,1)
    curqtl <- addtoqtl(cross, qtl, as.character(out[wh,1]), out[wh,2],
                       paste("Q", n.qtl+1, sep=""))
    curformula <- as.formula(paste(deparseQTLformula(formula), "+Q", n.qtl+1, sep=""))
    curlod <- curlod + lod 
    curplod <- calc.plod(curlod, countqtlterms(curformula, ignore.covar=TRUE),
                    penalties=penalties)
    if(verbose) cat("        plod =", curplod, "\n")

    curnqtl <- n.qtl+1

    if(!additive.only) {
      for(j in 1:n.qtl) {

        if(verbose)
          cat(" ---Scanning for QTL interacting with Q", j, "\n", sep="")

        thisformula <- as.formula(paste(deparseQTLformula(formula), "+Q", n.qtl+1,
                                        "+Q", j, ":Q", n.qtl+1, sep=""))
        out <- addqtl(cross, pheno.col=pheno.col, qtl=qtl, covar=covar,
                       formula=thisformula, method=method, incl.markers=incl.markers,
                       verbose=verbose.scan)
        thislod <- max(out[,3], na.rm=TRUE)

        wh <- which(!is.na(out[,3]) & out[,3]==thislod)
        if(length(wh) > 1) wh <- sample(wh,1)
        thisqtl <- addtoqtl(cross, qtl, as.character(out[wh,1]), out[wh,2],
                            paste("Q", n.qtl+1, sep=""))

        thislod <- thislod + lod
        thisplod <- calc.plod(thislod, countqtlterms(thisformula, ignore.covar=TRUE),
                         penalties=penalties)
        if(verbose) cat("        plod =", thisplod, "\n")

        if(thisplod > curplod) {
          curformula <- thisformula
          curplod <- thisplod
          curlod <- thislod
          curqtl <- thisqtl

          curnqtl <- n.qtl+1
        }
      }

      if(n.qtl > 1) {
        if(verbose)
          cat(" ---Look for additional interactions\n")
        temp <- addint(cross, pheno.col, qtl, covar=covar, formula=formula,
                       method=method, qtl.only=TRUE, verbose=verbose.scan)
        if(!is.null(temp)) {
          thislod <- max(temp[,3], na.rm=TRUE)
          wh <- which(!is.na(temp[,3]) & temp[,3] == thislod)
          if(length(wh) > 1) wh <- sample(wh, 1)
          thisformula <- as.formula(paste(deparseQTLformula(formula), "+", rownames(temp)[wh]))
          thislod <- thislod + lod
          thisplod <- calc.plod(thislod, countqtlterms(thisformula, ignore.covar=TRUE),
                           penalties=penalties)
          if(verbose) cat("        plod =", thisplod, "\n")
          if(thisplod > curplod) {
            curformula <- thisformula
            curplod <- thisplod
            curlod <- thislod
            curqtl <- qtl
            curnqtl <- n.qtl
          }
        }
      }

      if(scan.pairs) {
        if(verbose)
          cat(" ---Scan for an additional pair\n")
        out <- addpair(cross, pheno.col=pheno.col, qtl=qtl, covar=covar,
                       formula=formula, method=method, incl.markers=incl.markers,
                       verbose=verbose.scan)
        thelod <- out$lod
        
        loda <- max(thelod[upper.tri(thelod)], na.rm=TRUE)
        ploda <- calc.plod(loda+lod, c(2,0,0,0)+countqtlterms(formula, ignore.covar=TRUE),
                      penalties=penalties)
        lodf <- max(thelod[lower.tri(thelod)], na.rm=TRUE)
        plodf <- calc.plod(lodf+lod, c(2,0,1,1)+countqtlterms(formula, ignore.covar=TRUE),
                      penalties=penalties)

        if(verbose) {
          cat("        ploda =", ploda, "\n")
          cat("        plodf =", plodf, "\n")
        }

        if(ploda > curplod && loda > plodf) {
          temp <- max(out, what="add")
          if(nrow(temp) > 1)
            temp <- temp[sample(1:nrow(temp),1),]
          curqtl <- addtoqtl(cross, qtl, c(as.character(temp[1,1]), as.character(temp[1,2])),
                             c(temp[1,3], temp[1,4]), paste("Q", n.qtl+1:2, sep=""))
          curformula <- as.formula(paste(deparseQTLformula(formula), "+Q", n.qtl+1, "+Q",
                                         n.qtl+2, sep=""))
          curplod <- ploda
          lod <- loda+lod
          curnqtl <- n.qtl+2
        }
        else if(plodf > curplod) {
          temp <- max(out, what="full")
          if(nrow(temp) > 1)
            temp <- temp[sample(1:nrow(temp),1),]
          
          curqtl <- addtoqtl(cross, qtl, c(as.character(temp[1,1]), as.character(temp[1,2])),
                             c(temp[1,3], temp[1,4]), paste("Q", n.qtl+1:2, sep=""))
          curformula <- as.formula(paste(deparseQTLformula(formula), "+Q", n.qtl+1, "+Q",
                                         n.qtl+2, "+Q", n.qtl+1, ":Q", n.qtl+2, 
                                         sep=""))
          curplod <- plodf
          lod <- lodf+lod
          curnqtl <- n.qtl+2
        }
      }

    }

    qtl <- curqtl
    n.qtl <- curnqtl
    attr(qtl, "formula") <- deparseQTLformula(curformula)
    attr(qtl, "pLOD") <- curplod
    formula <- curformula
    lod <- curlod
    
    if(refine.locations) {
      if(verbose) cat(" ---Refining positions\n")
      rqtl <- refineqtl(cross, pheno.col=pheno.col, qtl=qtl,
                        covar=covar, formula=formula, method=method,
                        verbose=verbose.scan, incl.markers=incl.markers,
                        keeplodprofile=FALSE)
      if(any(rqtl$pos != qtl$pos)) { # updated positions
        if(verbose) cat(" ---  Moved a bit\n")
        qtl <- rqtl
        lod <- fitqtl(cross, pheno.col, qtl, covar=covar, formula=formula,
                      method=method, dropone=FALSE, get.ests=FALSE,
                      run.checks=FALSE)$result.full[1,4] - lod0
        curplod <- calc.plod(lod, countqtlterms(formula, ignore.covar=TRUE),
                        penalties=penalties)
        attr(qtl, "pLOD") <- curplod
      }

    }

    if(verbose)
      cat("    no.qtl = ", n.qtl, "  pLOD =", curplod, "  formula:",
          deparseQTLformula(formula), "\n")
    if(verbose > 1) 
      cat("         qtl:", paste(qtl$chr, round(qtl$pos,1), sep=":"), "\n")


    if(curplod > curbestplod) {
      if(verbose) 
        cat("** new best ** (pLOD increased by ", round(curplod - curbestplod, 4),
            ")\n", sep="")

      curbest <- qtl
      curbestplod <- curplod
    }

    if(keeptrace) {
      temp <- list(chr=qtl$chr, pos=qtl$pos)
      attr(temp, "formula") <- deparseQTLformula(formula)
      attr(temp, "pLOD") <- curplod
      class(temp) <- c("compactqtl", "list")
      temp <- list(temp)
      names(temp) <- i
      thetrace <- c(thetrace, temp)
    }

    if(n.qtl >= max.qtl) break
  }

  if(verbose) cat(" -Starting backward deletion\n")

  while(n.qtl > 1) {
    i <- i+1
    out <- fitqtl(cross, pheno.col, qtl, covar=covar, formula=formula,
                  method=method, dropone=TRUE, get.ests=FALSE,
                  run.checks=FALSE)$result.drop 

    rn <- rownames(out)
    # ignore things with covariates
    wh <- c(grep("^[Qq][0-9]+$", rn),
            grep("^[Qq][0-9]+:[Qq][0-9]+$", rn))
    out <- out[wh,,drop=FALSE]

    thelod <- out[,3]
    minlod <- min(thelod, na.rm=TRUE)

    wh <- which(!is.na(thelod) & thelod==minlod)
    if(length(wh) > 1) wh <- sample(wh, 1)

    lod <- lod - minlod
    todrop <- rownames(out)[wh]

    if(verbose) cat(" ---Dropping", todrop, "\n")

    if(length(grep(":", todrop)) > 0) { # dropping an interaction
      theterms <- attr(terms(formula), "factors")
      wh <- colnames(theterms)==todrop
      if(!any(wh)) stop("Confusion about what interation to drop!")
      theterms <- colnames(theterms)[!wh]
      formula <- as.formula(paste("y~", paste(theterms, collapse="+")))
    }
    else {
      numtodrop <- as.numeric(substr(todrop, 2, nchar(todrop)))

      theterms <- attr(terms(formula), "factors")
      cn <- colnames(theterms)
      g <- c(grep(paste("^[Qq]", numtodrop, "$", sep=""), cn),
             grep(paste("^[Qq]", numtodrop, ":", sep=""), cn),
             grep(paste(":[Qq]", numtodrop, "$", sep=""), cn))
      cn <- cn[-g]
      formula <- as.formula(paste("y~", paste(cn, collapse="+")))
      
      if(n.qtl > numtodrop) {
        for(j in (numtodrop+1):n.qtl)
          formula <- reviseqtlnuminformula(formula, j, j-1)
      }

      qtl <- dropfromqtl(qtl, index=numtodrop)
      qtl$name <- qtl$altname <- paste("Q", 1:qtl$n.qtl, sep="")
      n.qtl <- n.qtl - 1
    }

    curplod <- calc.plod(lod, countqtlterms(formula, ignore.covar=TRUE),
                    penalties=penalties)

    if(verbose)
      cat("    no.qtl = ", n.qtl, "  pLOD =", curplod, "  formula:",
          deparseQTLformula(formula), "\n")
    if(verbose > 1) 
      cat("         qtl:", paste(qtl$chr, round(qtl$pos,1), sep=":"), "\n")

    attr(qtl, "formula") <- deparseQTLformula(formula)
    attr(qtl, "pLOD") <- curplod
      
    if(refine.locations) {
      if(verbose) cat(" ---Refining positions\n")
      if(!is.null(qtl)) {
        rqtl <- refineqtl(cross, pheno.col=pheno.col, qtl=qtl,
                          covar=covar, formula=formula, method=method,
                          verbose=verbose.scan, incl.markers=incl.markers,
                          keeplodprofile=FALSE)
        if(any(rqtl$pos != qtl$pos)) { # updated positions
          if(verbose) cat(" ---  Moved a bit\n")
          qtl <- rqtl
          lod <- fitqtl(cross, pheno.col, qtl, covar=covar, formula=formula,
                        method=method, dropone=FALSE, get.ests=FALSE,
                        run.checks=FALSE)$result.full[1,4] - lod0
          curplod <- calc.plod(lod, countqtlterms(formula, ignore.covar=TRUE),
                          penalties=penalties)
          attr(qtl, "pLOD") <- curplod
        }
      }
    }

    if(curplod > curbestplod) {
      if(verbose) 
        cat("** new best ** (pLOD increased by ", round(curplod - curbestplod, 4),
            ")\n", sep="")

      curbestplod <- curplod
      curbest <- qtl
    }

    if(keeptrace) {
      temp <- list(chr=qtl$chr, pos=qtl$pos)
      attr(temp, "formula") <- deparseQTLformula(formula)
      attr(temp, "pLOD") <- curplod
      class(temp) <- c("compactqtl", "list")
      temp <- list(temp)
      names(temp) <- i
      thetrace <- c(thetrace, temp)
    }
  }

  # re-form the qtl
  if(!is.null(curbest)) {
    chr <- curbest$chr
    pos <- curbest$pos
    o <- order(factor(chr, levels=names(cross$geno)), pos)

    qtl <- makeqtl(cross, chr[o], pos[o], what=qtlmethod)
    
    # need to redo numbering in formula
    formula <- as.formula(attr(curbest, "formula"))

    if(length(chr) > 1) {
      n.qtl <- length(chr)
      for(i in 1:n.qtl)
        formula <- reviseqtlnuminformula(formula, i, n.qtl+i)
      for(i in 1:n.qtl)
        formula <- reviseqtlnuminformula(formula, n.qtl+o[i], i)
    }
    
    if(keeplodprofile) {
      if(verbose) cat(" ---One last pass through refineqtl\n")
      qtl <- refineqtl(cross, pheno.col=pheno.col, qtl=qtl,
                       covar=covar, formula=formula, method=method,
                       verbose=verbose.scan, incl.markers=incl.markers,
                       keeplodprofile=TRUE)
    }
    attr(qtl, "formula") <- deparseQTLformula(formula)
    attr(qtl, "pLOD") <- attr(curbest, "pLOD")
    curbest <- qtl
  }
  else {
    curbest <- numeric(0)
    class(curbest) <- "qtl"
    attr(curbest,"pLOD") <- 0
  }
    
  if(keeptrace)
    attr(curbest, "trace") <- thetrace

  curbest
}
  

######################################################################
# check initial qtl model for appropriateness
######################################################################
checkStepwiseqtlStart <-
function(qtl, formula, covar=NULL)
{
  if(is.character(formula)) formula <- as.formula(formula)

  formula <- checkformula(formula, qtl$altname, colnames(covar))
  theterms <- attr(terms(formula), "factors")[-1,,drop=FALSE]
  rn <- rownames(theterms)
      
  # make sure that all covariates in covar exist in the formula
  if(!is.null(covar)) {
    covarnam <- colnames(covar)
    m <- is.na(match(covarnam, rn))
    if(any(m)) {
      toadd <- covarnam[m]
      warning("Adding ", paste(toadd, collapse="+"), " to formula")
      formula <- as.formula(paste(deparseQTLformula(formula), "+", paste(toadd, collapse="+"), sep=""))
      theterms <- attr(terms(formula), "factors")[-1,,drop=FALSE]
      rn <- rownames(theterms)
    }
        
    # make sure there are no QTL:covariate interactions
    theqtl <- grep("^Q[0-9]+$", rn)
    thecovar <- seq(along=rn)[-theqtl]
    
    if(any(apply(theterms[thecovar,,drop=FALSE], 1, sum)>1))
      stop("We can't yet handle QTL:covariate or covariate:covariate interactions")
  }

  # make sure that any QTL in formula exist in object
  theqtl <- grep("^Q[0-9]+$", rn)
  thecovar <- seq(along=rn)[-theqtl]
  qtlindex <- as.numeric(substr(rn[theqtl], 2, nchar(rn[theqtl])))
  wh <- qtlindex < 0 | qtlindex > length(qtl$chr)
  if(any(wh))
    stop("QTL ", paste(rn[theqtl][wh], collapse=" "), " not in qtl object")


  # make sure that there are not any extraneous terms
  if(length(thecovar) > 0) {
    if(is.null(covar))
      stop("Extraneous terms in formula: ", paste(rn[thecovar], collapse=" "))
    else {
      wh <- is.na(match(rn[thecovar], colnames(covar)))
      if(any(wh))
        stop("Extraneous terms in formula: ", paste(rn[thecovar][wh], collapse=" "))
    }
  }

  # if any QTL not referred to in formula, drop them from the QTL object
  todrop <- seq(along=qtl$chr)[-qtlindex]
  if(length(todrop) > 0) {
    oldnum <- seq(along=qtl$chr)[-todrop]
    newnum <- order(oldnum)

    formula <- reviseqtlnuminformula(formula, oldnum, newnum)
    qtl <- dropfromqtl(qtl, todrop)
  }

  return(list(qtl=qtl, formula=as.formula(formula)))
}


######################################################################
# penalized LOD score
######################################################################
calc.plod <-
function(lod, nterms, type=c("f2","bc"), penalties)
  as.numeric(lod - nterms[1]*penalties[1] - nterms[2]*penalties[2] - nterms[3]*penalties[3])

######################################################################
# count terms in a model, for use by plod
######################################################################
countqtlterms <-
function(formula, ignore.covar=TRUE)
{
  if(is.character(formula)) formula <- as.formula(formula)
  factors <- attr(terms(formula), "factors")[-1,,drop=FALSE]
  if(any(factors > 1))  {
    warning("some formula terms > 1; may be a problem with the formula:\n    ", deparseQTLformula(formula))
    factors[factors > 1] <- 1
  }
  nterm <- apply(factors, 2, sum)

  if(any(nterm>2)) 
    stop("Can't deal with higher-order interactions\n")

  # need to check for QTL x covariate interactions in here!

  if(ignore.covar) {
    cn <- colnames(factors)
    wh <- c(grep("^[Qq][0-9]+$", cn),
            grep("^[Qq][0-9]+:[Qq][0-9]+$", cn))
    rn <- rownames(factors)
    wh2 <- c(grep("^[Qq][0-9]+$", rn),
            grep("^[Qq][0-9]+:[Qq][0-9]+$", rn))
    factors <- factors[wh2,wh, drop=FALSE]
  }
  nterm <- apply(factors, 2, sum)

  nmain <- sum(nterm==1)

  if(all(nterm==1))
    return(c(main=nmain, intH=0, intL=0))

  n.int <- sum(nterm==2)
  
  factors <- factors[,nterm==2, drop=FALSE]

  wh <- apply(factors, 2, function(a) which(a==1))

  u <- sort(unique(as.numeric(wh)))
  grp <- rep(NA, length(u))
  names(grp) <- u

  ngrp <- 0
  nint <- NULL

  for(i in 1:ncol(wh)) {
    thegrp <- grp[as.character(wh[,i])]
    if(all(!is.na(thegrp))) {
      nint[as.character(thegrp[1])] <-
        sum(nint[unique(as.character(thegrp))]) + 1
      grp[grp==thegrp[1] | grp==thegrp[2]] <- thegrp[1]
    }
    else if(any(!is.na(thegrp))) {
      grp[as.character(wh[,i])] <- thegrp[!is.na(thegrp)]
      nint[as.character(thegrp[!is.na(thegrp)])] <- 
           nint[as.character(thegrp[!is.na(thegrp)])] + 1
    }
    else {
      ngrp <- ngrp+1
      grp[as.character(wh[,i])] <- ngrp
      nint[as.character(ngrp)] <- 1
    }
  }

  nint <- nint[as.character(unique(grp))]
  nL <- sum(nint>0)
  nH <- sum(nint)-nL
  c(main=nmain, intH=nH, intL=nL, inttot=n.int)
}
  
######################################################################
# calculate penalties for pLOD using scantwo permutation results.
######################################################################
calc.penalties <-
function(perms, alpha=0.05)
{
  if(missing(perms) || !("scantwoperm" %in% class(perms)))
    stop("You must include permutation results from scantwo.")

  qu <- summary(perms, alpha=alpha)
  if(!("one" %in% names(qu)))
    stop("You need to re-run scantwo permutations with R/qtl version >= 1.09.")

  if(length(alpha)>1) {
    penalties <- cbind(qu[["one"]], qu[["int"]], qu[["fv1"]]-qu[["one"]])
    colnames(penalties) <- c("main","heavy", "light")
  }
  else {
    penalties <- c(qu[["one"]], qu[["int"]], qu[["fv1"]]-qu[["one"]])
    names(penalties) <- c("main","heavy", "light")
  }
  penalties
}

# end of stepwiseqtl.R