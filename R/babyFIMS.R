library(RTMB)
load("data/am2022.RData")

head(input$obsdf) # long format with all observations
# obs_type # 0=catch, 1=index, 2=agecom, 3=lencomp
# nll_type # 0=dnorm, 1=dmultinom
# fit_data # 1/0=TRUE/FALSE
# fleet    # 1=fishery, 2=survey
# obs      # transformed appropriately for nll_type (becomes keep vec)
# obserror # if nll_type obs error is an input (note this is Neff for dmultinom)

dat <- list()
dat$obs <- input$obsdf$obs
dat$aux <- input$obsdf
dat$years <- input$years
dat$minAge <- min(fit$data$minAgePerFleet)
dat$fleetTypes <- fit$data$fleetTypes
dat$sampleTimes <- fit$data$sampleTimes
dat$year <- fit$data$years
dat$age <-  min(fit$data$minAgePerFleet):max(fit$data$maxAgePerFleet)   
dat$M <- fit$data$natMor
dat$SW <- fit$data$stockMeanWeight
dat$MO <- fit$data$propMat
dat$PF <- fit$data$propF
dat$PM <- fit$data$propM

dat$srmode <- 2
dat$fcormode <- 2
dat$keyF <- fit$conf$keyLogFsta[1,]+1
dat$keyQ <- fit$conf$keyLogFpar+1
dat$keySd <- fit$conf$keyVarObs+1; dat$keySd[dat$keySd<=0] <- NA
dat$fleetDim <- apply(dat$keySd,1,function(x)sum(!is.na(x)))
dat$covType <-  as.integer(fit$conf$obsCorStruct)-1 # c(0,1,2)
dat$keyIGAR <- fit$conf$keyCorObs +1 ; dat$keyIGAR[fit$conf$keyCorObs==0] <- NA
dat$keyIGAR[is.na(fit$conf$keyCorObs)] <- -1
#dat$keyIGAR[2, 1:4] <- 1

par <- list()
par$logsdR <- 0
par$logsdS <- 0
par$logsdF <- numeric(max(dat$keyF))
par$rickerpar <- if(dat$srmode==1){c(1,1)}else{numeric(0)}
par$transRhoF <- if(dat$fcormode==0){numeric(0)}else{0.1}
par$bhpar <- if(dat$srmode==2){c(1,1)}else{numeric(0)}
par$logQ <- numeric(max(dat$keyQ, na.rm=TRUE))-5
par$logsdO <- numeric(max(dat$keySd, na.rm=TRUE))
par$logIGARdist <- if(sum(dat$covType==1)==0){numeric(0)}else{numeric(max(dat$keyIGAR,na.rm=TRUE))}
par$parUS <- unlist(sapply(1:length(dat$covType), function(f)if(dat$covType[f]==2)unstructured(dat$fleetDim[f])$parms()))
par$missing <- numeric(sum(is.na(dat$logobs)))
par$logN <- matrix(0, nrow=length(dat$year), ncol=length(dat$age))
par$logF <- matrix(0, nrow=length(dat$year), ncol=max(dat$keyF))

ssbFUN <- function(N, F, M, SW, MO, PF, PM){
  rowSums(N*exp(-PF*F-PM*M)*MO*SW)
}

f<-function(par){
  getAll(par,dat)
  logobs <- OBS(logobs)
  logobs[is.na(logobs)] <- missing
  nobs <- length(logobs)    
  nrow <- nrow(M)
  ncol <- ncol(M)
  sdR <- exp(logsdR)
  sdS <- exp(logsdS)
  sdF <- exp(logsdF)      
  sdO <- exp(logsdO)
  logFF <- logF[,keyF] ## expand F
  F <- exp(logFF)
  ssb <- ssbFUN(exp(logN),exp(logFF),M,SW,MO,PF,PM)
  
  jnll <- 0
  
  for(y in 2:nrow){
    thisSSB <- ifelse((y-minAge-1)>(-.5),ssb[y-minAge],ssb[1]) 
    if(srmode==0){ #RW
      pred <- logN[y-1,1]
    }
    if(srmode==1){ #Ricker
      pred <- rickerpar[1]+log(thisSSB)-exp(rickerpar[2])*thisSSB
    }
    if(srmode==2){ #BH
      pred <- bhpar[1]+log(thisSSB)-log(1.0+exp(bhpar[2])*thisSSB)
    }
    if(!(srmode%in%c(0,1,2))){
      stop(paste("srmode", srmode,"not implemented yet"))
    }      
    jnll <- jnll - dnorm(logN[y,1],pred,sdR,log=TRUE)
  }  
  for(y in 2:nrow){
    for(a in 2:ncol){
      pred <- logN[y-1,a-1]-F[y-1,a-1]-M[y-1,a-1]
      if(a==ncol){
        pred <- log(exp(pred)+exp(logN[y-1,a]-F[y-1,a]-M[y-1,a]))
      }
      jnll <- jnll - dnorm(logN[y,a],pred,sdS,log=TRUE)
    }
  }
  
  SigmaF <- matrix(0, ncol(logF),ncol(logF))
  if(fcormode==0){
    diag(SigmaF) <- sdF*sdF
  }
  if(fcormode==1){
    diag(SigmaF) <- sdF*sdF
    rhoF <- 2*plogis(transRhoF[1])-1
    for(i in 2:ncol(logF)){
      for(j in 1:(i-1)){
        SigmaF[i,j] <- rhoF*sdF[i]*sdF[j]
        SigmaF[j,i] <- SigmaF[i,j] 
      }
    }
  }
  if(fcormode==2){
    diag(SigmaF) <- sdF*sdF
    rhoF <- 2*plogis(transRhoF[1])-1
    for(i in 2:ncol(logF)){
      for(j in 1:(i-1)){
        SigmaF[i,j] <- sdF[i]*sdF[j]*(rhoF^(i-j))
        SigmaF[j,i] <- SigmaF[i,j] 
      }
    }
  }
  for(y in 2:nrow){
    jnll <- jnll - dmvnorm(logF[y,],logF[y-1,],SigmaF,log=TRUE)
  }
  
  logPred <- numeric(nobs)  
  for(i in 1:nobs){
    y <- aux[i,1]-minYear+1
    f <- aux[i,2]
    a <- aux[i,3]-minAge+1
    Z <- F[y,a]+M[y,a]
    if(fleetTypes[f]==0){
      logPred[i] <- logN[y,a]-log(Z)+log(1-exp(-Z))+log(F[y,a])
    }
    if(fleetTypes[f]==2){  
      logPred[i] <- logQ[keyQ[f,a]]+logN[y,a]-Z*sampleTimes[f]
    }
    if(!(fleetTypes[f]%in%c(0,2))){  
      stop("This fleet type is has not been implemented yet")
    }
  }
  Slist<-list()
  for(f in unique(aux[,2])){ # each fleet
    if(covType[f]==0){# independent      
      S <- diag(sdO[na.omit(keySd[f,])]^2)
    }
    if(covType[f]==1){# IGAR      
      S <- diag(sdO[na.omit(keySd[f,])]^2)  
      dist <- cumsum(c(0,exp(logIGARdist[na.omit(keyIGAR[f,])])))
      for(i in 2:ncol(S)){
        for(j in 1:(i-1)){
          S[i,j] <- sqrt(S[i,i])*sqrt(S[j,j])*(0.5^(dist[i]-dist[j]))
          S[j,i] <- S[i,j]
        }
      }
    }
    if(covType[f]==2){# US
      idx <- which(f==unlist(sapply(1:length(dat$covType), function(f)if(dat$covType[f]==2)unstructured(dat$fleetDim[f])$parms()+f))) 
      D <- diag(sdO[na.omit(keySd[f,])])
      R <- unstructured(nrow(D))$corr(parUS[idx])
      S <- D%*%R%*%D
    }
    if(!covType[f]%in%c(0,1,2)){#       
      stop("Covariance type not implemented")
    }
    Slist[[length(Slist)+1]]<-S    
    for(y in unique(aux[,1])){ # year within fleet 
      idx <- which((aux[,2]==f) & (aux[,1]==y))
      if(length(idx)!=0){
        jnll <- jnll - dmvnorm(logobs[idx],logPred[idx],S,log=TRUE)  
      }
    }
  }
  REPORT(Slist)
  REPORT(logPred)
  logssb<-log(ssb)
  ADREPORT(logssb)
  jnll
}    

obj <- MakeADFun(f, par, 
                 #random=c("logN", "logF", "missing"), 
                 map=list(logsdF=as.factor(rep(0,length(par$logsdF)))), 
                 silent=FALSE)
opt <- nlminb(obj$par, obj$fn, obj$gr, control=list(eval.max=1000, iter.max=1000))
opt$objective

sdr <- sdreport(obj)
plr <- as.list(sdr,report=TRUE, "Est")
plrsd <- as.list(sdr,report=TRUE, "Std")
lines(dat$year, exp(plr$logssb), lwd=3, col="darkred")
lines(dat$year, exp(plr$logssb-2*plrsd$logssb), lwd=3, col="darkred", lty="dotted")
lines(dat$year, exp(plr$logssb+2*plrsd$logssb), lwd=3, col="darkred", lty="dotted")