# GenomicsWorkflow

This repository contains codes for optimizing and benchmarking Broad's Whole genome sequencing analysis pipeline with CROMWELL workflow manager and WDL scripts.

The comparisions include:

    Baseline : Config File for Baseline.20K.
    Baseline.20k : BWA-Mem, Samtools, Picard (No Multiprocessing, GATK)
    Mem2.20K : 20K reads with BWA-Mem2 rather than BWA-Mem in the pipeline
    Mem2.json : Config file for Mem2.20K.
    Minimap2. : Uses Minimap2 as aligner rather than BWA-Mem.
    Sparks: Uses MarkDuplicateSparks for parallel processing of samtools and picard markduplicates.

