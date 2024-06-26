# Author: M, de Celis Rodriguez
# Date: 13/07/2022
# Project: Wineteractions - ITS sequence analysis of GM samples

library(dada2)
library(ShortRead)
library(Biostrings)


rm(list=ls()) #Clear R environment

# Set the project location as working directory
setwd("~/../OneDrive - Universidad Complutense de Madrid (UCM)/Wineteractions/GitHub/Wineteractions/")

#
#### CUSTOM FUNCTIONS ####
getN <- function(x) sum(getUniques(x))

allOrients <- function(primer) {
  # Create all orientations of the input sequence
  require(Biostrings)
  dna <- DNAString(primer)  # The Biostrings works w/ DNAString objects rather than character vectors
  orients <- c(Forward = dna, Complement = complement(dna), Reverse = reverse(dna), 
               RevComp = reverseComplement(dna))
  return(sapply(orients, toString))  # Convert back to character vector
}

primerHits <- function(primer, fn) {
  # Counts number of reads in which the primer is found
  nhits <- vcountPattern(primer, sread(readFastq(fn)), fixed = FALSE)
  return(sum(nhits > 0))
}

#
#### GETTING READY ####

sample_GM <- read.table("Data/Metadata/sample_GM.txt", header = TRUE, sep = "\t")
sample_SGM <- read.table("Data/Metadata/sample_SGM.txt", header = TRUE, sep = "\t")

path <- "Data/Sequencing/Raw_Reads/"

fnFs <- sort(list.files(file.path(path, "R1"), pattern = ".fastq.gz", full.names = TRUE))
fnRs <- sort(list.files(file.path(path, "R2"), pattern = ".fastq.gz", full.names = TRUE))

sample.names <- sapply(strsplit(basename(fnFs), "_"), `[`, 1)
sample.names <- gsub("NGS025-21-ITS2-", "ITS-", sample.names)
sample.names <- gsub("NGS025-21-RUN-2-", "", sample.names)

#Identify Primers
FWD <- "TCCTCCGCTTATTGATATGC"
REV <- "GTGARTCATCGAATCTTTG"

FWD.orients <- allOrients(FWD)
REV.orients <- allOrients(REV)

#
#### REMOVE Ns ####
fnFs.filtN <- file.path(path, "R1/Remove.primers/filtN", basename(fnFs))
fnRs.filtN <- file.path(path, "R2/Remove.primers/filtN", basename(fnRs))

filtN <- filterAndTrim(fnFs, fnFs.filtN, fnRs, fnRs.filtN, maxN = 0, verbose = TRUE)

#
#### REMOVE PRIMERS ####
rbind(FWD.ForwardReads = sapply(FWD.orients, primerHits, fn = fnFs.filtN[[2]]), 
      FWD.ReverseReads = sapply(FWD.orients, primerHits, fn = fnRs.filtN[[2]]), 
      REV.ForwardReads = sapply(REV.orients, primerHits, fn = fnFs.filtN[[2]]), 
      REV.ReverseReads = sapply(REV.orients, primerHits, fn = fnRs.filtN[[2]]))

#Set cutadapt path
cutadapt <- "Data/Sequencing/cutadapt.exe"
system2(cutadapt, args = "--version")

fnFs.cut <- file.path(path, "R1/Remove.primers/cutadapt", basename(fnFs))
fnRs.cut <- file.path(path, "R2/Remove.primers/cutadapt", basename(fnRs))

# Run Cutadapt
for(i in seq_along(fnFs)) {
  system2(cutadapt, args = c("-g", REV, "-G", FWD,
                             "-o", fnFs.cut[i], "-p", fnRs.cut[i],
                             fnFs.filtN[i], fnRs.filtN[i]))
}

rbind(FWD.ForwardReads = sapply(FWD.orients, primerHits, fn = fnFs.cut[[2]]), 
      FWD.ReverseReads = sapply(FWD.orients, primerHits, fn = fnRs.cut[[2]]), 
      REV.ForwardReads = sapply(REV.orients, primerHits, fn = fnFs.cut[[2]]), 
      REV.ReverseReads = sapply(REV.orients, primerHits, fn = fnRs.cut[[2]]))

#### INSPECT QUALITY PROFILES ####
plotQualityProfile(fnFs.cut[sample(1:length(sample.names), 3)])
plotQualityProfile(fnRs.cut[sample(1:length(sample.names), 3)])

#
#### FILTER AND TRIM ####
filtFs <- file.path(path, "R1/Remove.primers/filtered", basename(fnFs))
filtRs <- file.path(path, "R2/Remove.primers/filtered", basename(fnRs))

out.cut <- filterAndTrim(fnFs.cut, filtFs, fnRs.cut, filtRs, truncLen = c(220,150),
                         maxN = 0, maxEE = c(2,2), truncQ = 2, rm.phix = TRUE,
                         compress = TRUE, verbose = TRUE) 

#
#### LEARN ERROR RATES ####
errF <- learnErrors(filtFs, multithread = FALSE)
errR <- learnErrors(filtRs, multithread = FALSE)

plotErrors(errF, nominalQ = TRUE)

#
#### SAMPLE INFERENCE ####
dadaFs <- dada(filtFs, err = errF, multithread = FALSE)
dadaRs <- dada(filtRs, err = errR, multithread = FALSE)

#
#### MERGE PAIRED READS ####
mergers <- mergePairs(dadaFs, filtFs, dadaRs, filtRs, verbose = TRUE, minOverlap = 5)

#
#### CONSTRUCT SEQUENCE TABLE ####
seqtab <- makeSequenceTable(mergers)
dim(seqtab)
hist(nchar(getSequences(seqtab)))

row.names(seqtab) <- sapply(strsplit(row.names(seqtab), "_"), `[`, 1)
row.names(seqtab) <- gsub("NGS025-21-ITS2-", "ITS-", row.names(seqtab))
row.names(seqtab) <- gsub("NGS025-21-RUN-2-", "", row.names(seqtab))

#
#### REMOVE CHIMERAS ####
seqtab.nochim <- removeBimeraDenovo(seqtab, method = "consensus", verbose = TRUE)
dim(seqtab.nochim)
sum(seqtab.nochim)/sum(seqtab)

#
#### TRACK READS ####
track.cut <- cbind.data.frame(filtN[,1], out.cut[,2], sapply(dadaFs, getN), 
                              sapply(dadaRs, getN), sapply(mergers, getN), 
                              rowSums(seqtab.nochim))

colnames(track.cut) <- c("input", "filtered", "denoisedF", "denoisedR", "merged", "nonchim")
row.names(track.cut) <- sample.names

track.cut <- cbind.data.frame(track.cut, perc = track.cut[,6]*100/track.cut[,1])

#
#### ASSIGN TAXONOMY ####
taxa.cut <- assignTaxonomy(seqtab.nochim, 
                           "Data/Sequencing/Databases/sh_general_release_dynamic_s_29.11.2022.fasta")

#
#### EXPORT TABLES ####

write.table(track.cut, "Data/Sequencing/Outputs/track_GM.txt", sep = "\t", dec = ",")

## GM
asv_GM <- seqtab.nochim[row.names(seqtab.nochim) %in% sample_GM$Seq_ID, ]
asv_GM <- asv_GM[,colSums(asv_GM) > 0]
taxa.cut_GM <- taxa.cut[colnames(asv_GM),]

saveRDS(taxa.cut_GM, "Data/Sequencing/Outputs/tax_GM.rds")
saveRDS(asv_GM, "Data/Sequencing/Outputs/ASV_GM.rds")

## SGM
asv_SGM <- seqtab.nochim[row.names(seqtab.nochim) %in% sample_SGM$Sample_ID, ]
asv_SGM <- asv_SGM[,colSums(asv_SGM) > 0]
taxa.cut_SGM <- taxa.cut[colnames(asv_SGM),]

saveRDS(taxa.cut_SGM, "Data/Sequencing/Outputs/tax_SGM.rds")
saveRDS(asv_SGM, "Data/Sequencing/Outputs/ASV_SGM.rds")

#