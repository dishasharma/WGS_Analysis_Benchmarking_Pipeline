## Copyright Broad Institute, 2017
##
## This WDL pipeline implements data pre-processing and initial variant calling (GVCF
## generation) according to the GATK Best Practices (June 2016) for germline SNP and
## Indel discovery in human whole-genome sequencing (WGS) data.
##
## Requirements/expectations :
## - Human whole-genome pair-end sequencing data in unmapped BAM (uBAM) format
## - One or more read groups, one per uBAM file, all belonging to a single sample (SM)
## - Input uBAM files must additionally comply with the following requirements:
## - - filenames all have the same suffix (we use ".unmapped.bam")
## - - files must pass validation by ValidateSamFile
## - - reads are provided in query-sorted order
## - - all reads must have an RG tag
## - GVCF output names must end in ".g.vcf.gz"
## - Reference genome must be Hg38 with ALT contigs
##
## Runtime parameters are optimized for Broad's Google Cloud Platform implementation.
## For program versions, see docker containers.
##
## LICENSING :
## This script is released under the WDL source code license (BSD-3) (see LICENSE in
## https://github.com/broadinstitute/wdl). Note however that the programs it calls may
## be subject to different licenses. Users are responsible for checking that they are
## authorized to run all programs before running this script. Please see the docker
## page at https://hub.docker.com/r/broadinstitute/genomes-in-the-cloud/ for detailed
## licensing information pertaining to the included programs.

# TASK DEFINITIONS

# Collect sequencing yield quality metrics
task CollectQualityYieldMetrics {
  File input_bam
  String metrics_filename
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path

  command {
    java -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectQualityYieldMetrics \
      INPUT=${input_bam} \
      OQ=true \
      OUTPUT=${metrics_filename}
  }
  runtime {
    memory: memory
    cpu: cpu
    backend: "Local"
  }
  output {
    File metrics = "${metrics_filename}"
  }
}

# Check the assumption that the final GVCF filename that is going to be used ends with .g.vcf.gz
task CheckFinalVcfExtension {
  String vcf_filename
  String memory
  Int cpu

  command <<<
    python <<CODE
    import os
    import sys
    filename="${vcf_filename}"
    if not filename.endswith(".g.vcf.gz"):
      raise Exception("input","gvcf output filename must end with '.g.vcf.gz', found %s"%(filename))
      sys.exit(1)
    CODE
  >>>
  runtime {
    memory: memory
    cpu: cpu
    backend: "Local"
  }
  output {
    String common_suffix=read_string(stdout())
  }
}

# Get version of BWA
task GetBwaVersion {
  String memory
  Int cpu
  String tool_path

  command {
    # not setting set -o pipefail here because /bwa has a rc=1 and we dont want to allow rc=1 to succeed because
    # the sed may also fail with that error and that is something we actually want to fail on.
    ${tool_path}/bwa/bwa 2>&1 | \
    grep -e '^Version' | \
    sed 's/Version: //'
  }
  runtime {
    memory: memory
    cpu: cpu
    backend: "Local"
  }
  output {
    String version = read_string(stdout())
  }
}
task GetFastqName {
  String memory
  Int cpu
  String unmapped_fastq

  command <<<
    set -e
    set -o pipefail
    # not setting set -o pipefail here because /bwa has a rc=1 and we dont want to allow rc=1 to succeed because
    # the sed may also fail with that error and that is something we actually want to fail on.
    ls ${unmapped_fastq} | awk -F'_R1' '{ print $1}'
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    String FastqName = read_string(stdout())
  }
}

# Read unmapped BAM, convert on-the-fly to FASTQ and stream to BWA MEM for alignment, then stream to MergeBamAlignment
task SamToFastqAndBwaMemAndMba {
  String bwa_commandline
  String bwa_version
  String output_bam_basename
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  String tool_path
  String FastqName
  
  # This is the .alt file from bwa-kit (https://github.com/lh3/bwa/tree/master/bwakit),
  # listing the reference contigs that are "alternative".
  File ref_alt

  File ref_amb
  File ref_ann
  File ref_bwt
  File ref_pac
  File ref_sa
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu 
  Int bwa_threads

  command <<<
    set -o pipefail
    set -e

    # set the bash variable needed for the command-line
    bash_ref_fasta=${ref_fasta}
    bwa_threads=${bwa_threads}
    # if ref_alt has data in it,
    if [ -s ${ref_alt} ]; then
      cat ${FastqName}*.fastq | \
      ${tool_path}/${bwa_commandline} /dev/stdin - 2> >(tee ${output_bam_basename}.bwa.stderr.log >&2) > ${output_bam_basename}.bam

      grep -m1 "read .* ALT contigs" ${output_bam_basename}.bwa.stderr.log | \
      grep -v "read 0 ALT contigs"
    # else ref_alt is empty or could not be found
    else
      exit 1;
    fi
  >>>
  runtime {
    memory: memory
    cpu: cpu
 #   backend: "Local"
  }
  output {
    File output_bam = "${output_bam_basename}.bam"
    File bwa_stderr_log = "${output_bam_basename}.bwa.stderr.log"
  }
}

# Sort BAM file by coordinate order and fix tag values for NM and UQ
task SortSam {
  File input_bam
  String output_bam_basename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      SortSam \
      INPUT=${input_bam} \
      OUTPUT=${output_bam_basename}.bam \
      SORT_ORDER="queryname" \
      CREATE_INDEX=true \
      CREATE_MD5_FILE=true \
      MAX_RECORDS_IN_RAM=2700000
  >>>
  runtime {
    cpu: cpu 
    memory: memory
  }
  output {
    File output_bam = "${output_bam_basename}.bam"
    File output_bam_index = "${output_bam_basename}.bai"
    File output_bam_md5 = "${output_bam_basename}.bam.md5"
  }
}

# Sort BAM file by coordinate order and fix tag values for NM and UQ
task SamtoolsSort {
  File input_bam
  String output_bam_basename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  Int samtools_threads
  String mem_limit 
  String tool_path
 
  command <<<
    set -o pipefail
    set -e
    ${tool_path}/samtools-1.9/samtools sort -T $TMPDIR/${output_bam_basename}.bam.tmp -m ${mem_limit} -n --threads ${samtools_threads} -l ${compression_level} ${input_bam} -o ${output_bam_basename}.bam
    ${tool_path}/samtools-1.9/samtools index ${output_bam_basename}.bam ${output_bam_basename}.bai
  >>>
  runtime {
    cpu: cpu
    memory: memory
  }
  output {
    File output_bam = "${output_bam_basename}.bam"
    File output_bam_index = "${output_bam_basename}.bai"
#    File output_bam_md5 = "${output_bam_basename}.bam.md5"
  }
}

# Collect base quality and insert size metrics
task CollectUnsortedReadgroupBamQualityMetrics {
  File input_bam
  String output_bam_prefix
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectMultipleMetrics \
      INPUT=${input_bam} \
      OUTPUT=${output_bam_prefix} \
      ASSUME_SORTED=true \
      PROGRAM="null" \
      PROGRAM="CollectBaseDistributionByCycle" \
      PROGRAM="CollectInsertSizeMetrics" \
      PROGRAM="MeanQualityByCycle" \
      PROGRAM="QualityScoreDistribution" \
      METRIC_ACCUMULATION_LEVEL="null" \
      METRIC_ACCUMULATION_LEVEL="ALL_READS"

    touch ${output_bam_prefix}.insert_size_metrics
    touch ${output_bam_prefix}.insert_size_histogram.pdf
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File base_distribution_by_cycle_pdf = "${output_bam_prefix}.base_distribution_by_cycle.pdf"
    File base_distribution_by_cycle_metrics = "${output_bam_prefix}.base_distribution_by_cycle_metrics"
    File insert_size_histogram_pdf = "${output_bam_prefix}.insert_size_histogram.pdf"
    File insert_size_metrics = "${output_bam_prefix}.insert_size_metrics"
    File quality_by_cycle_pdf = "${output_bam_prefix}.quality_by_cycle.pdf"
    File quality_by_cycle_metrics = "${output_bam_prefix}.quality_by_cycle_metrics"
    File quality_distribution_pdf = "${output_bam_prefix}.quality_distribution.pdf"
    File quality_distribution_metrics = "${output_bam_prefix}.quality_distribution_metrics"
  }
}

# Collect alignment summary and GC bias quality metrics
task CollectReadgroupBamQualityMetrics {
  File input_bam
  File input_bam_index
  String output_bam_prefix
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectMultipleMetrics \
      INPUT=${input_bam} \
      REFERENCE_SEQUENCE=${ref_fasta} \
      OUTPUT=${output_bam_prefix} \
      ASSUME_SORTED=true \
      PROGRAM="null" \
      PROGRAM="CollectAlignmentSummaryMetrics" \
      PROGRAM="CollectGcBiasMetrics" \
      METRIC_ACCUMULATION_LEVEL="null" \
      METRIC_ACCUMULATION_LEVEL="READ_GROUP"
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File alignment_summary_metrics = "${output_bam_prefix}.alignment_summary_metrics"
    File gc_bias_detail_metrics = "${output_bam_prefix}.gc_bias.detail_metrics"
    File gc_bias_pdf = "${output_bam_prefix}.gc_bias.pdf"
    File gc_bias_summary_metrics = "${output_bam_prefix}.gc_bias.summary_metrics"
  }
}

# Collect quality metrics from the aggregated bam
task CollectAggregationMetrics {
  File input_bam
  File input_bam_index
  String output_bam_prefix
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectMultipleMetrics \
      INPUT=${input_bam} \
      REFERENCE_SEQUENCE=${ref_fasta} \
      OUTPUT=${output_bam_prefix} \
      ASSUME_SORTED=true \
      PROGRAM="null" \
      PROGRAM="CollectAlignmentSummaryMetrics" \
      PROGRAM="CollectInsertSizeMetrics" \
      PROGRAM="CollectSequencingArtifactMetrics" \
      PROGRAM="CollectGcBiasMetrics" \
      PROGRAM="QualityScoreDistribution" \
      METRIC_ACCUMULATION_LEVEL="null" \
      METRIC_ACCUMULATION_LEVEL="SAMPLE" \
      METRIC_ACCUMULATION_LEVEL="LIBRARY"

    touch ${output_bam_prefix}.insert_size_metrics
    touch ${output_bam_prefix}.insert_size_histogram.pdf
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File alignment_summary_metrics = "${output_bam_prefix}.alignment_summary_metrics"
    File bait_bias_detail_metrics = "${output_bam_prefix}.bait_bias_detail_metrics"
    File bait_bias_summary_metrics = "${output_bam_prefix}.bait_bias_summary_metrics"
    File gc_bias_detail_metrics = "${output_bam_prefix}.gc_bias.detail_metrics"
    File gc_bias_pdf = "${output_bam_prefix}.gc_bias.pdf"
    File gc_bias_summary_metrics = "${output_bam_prefix}.gc_bias.summary_metrics"
    File insert_size_histogram_pdf = "${output_bam_prefix}.insert_size_histogram.pdf"
    File insert_size_metrics = "${output_bam_prefix}.insert_size_metrics"
    File pre_adapter_detail_metrics = "${output_bam_prefix}.pre_adapter_detail_metrics"
    File pre_adapter_summary_metrics = "${output_bam_prefix}.pre_adapter_summary_metrics"
    File quality_distribution_pdf = "${output_bam_prefix}.quality_distribution.pdf"
    File quality_distribution_metrics = "${output_bam_prefix}.quality_distribution_metrics"
  }
}

task CrossCheckFingerprints {
  Array[File] input_bams
  Array[File] input_bam_indexes
  File? haplotype_database_file
  String metrics_filename
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path

  command <<<
    java -Dsamjdk.buffer_size=131072 \
      -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xmx${java_heap_memory_initial} \
      -jar ${tool_path}/picard.jar \
      CrosscheckReadGroupFingerprints \
      OUTPUT=${metrics_filename} \
      HAPLOTYPE_MAP=${haplotype_database_file} \
      EXPECT_ALL_READ_GROUPS_TO_MATCH=true \
      INPUT=${sep=' INPUT=' input_bams} \
      LOD_THRESHOLD=-20.0
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File metrics = "${metrics_filename}"
  }
}


# Check that the fingerprint of the sample BAM matches the sample array
task CheckFingerprint {
  File input_bam
  File input_bam_index
  String output_basename
  File? haplotype_database_file
  File? genotypes
  String sample
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    java -Dsamjdk.buffer_size=131072 \
      -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xmx${java_heap_memory_initial}  \
      -jar ${tool_path}/picard.jar \
      CheckFingerprint \
      INPUT=${input_bam} \
      OUTPUT=${output_basename} \
      GENOTYPES=${genotypes} \
      HAPLOTYPE_MAP=${haplotype_database_file} \
      SAMPLE_ALIAS="${sample}" \
      IGNORE_READ_GROUPS=true
  >>>
 runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File summary_metrics = "${output_basename}.fingerprinting_summary_metrics"
    File detail_metrics = "${output_basename}.fingerprinting_detail_metrics"
  }
}

# Mark duplicate reads to avoid counting non-independent observations
task MarkDuplicatesSpark {
  Array[File] input_bams
  String output_bam_basename
  #String output_bam_basename_index
  String metrics_filename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  # The program default for READ_NAME_REGEX is appropriate in nearly every case.
  # Sometimes we wish to supply "null" in order to turn off optical duplicate detection
  # This can be desirable if you don't mind the estimated library size being wrong and optical duplicate detection is taking >7 days and failing
  String? read_name_regex

 # Task is assuming query-sorted input so that the Secondary and Supplementary reads get marked correctly
 # This works because the output of BWA is query-grouped and therefore, so is the output of MergeBamAlignment.
 # While query-grouped isn't actually query-sorted, it's good enough for MarkDuplicates with ASSUME_SORT_ORDER="queryname"
 command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -XX:+PrintFlagsFinal \
      -XX:+PrintGCTimeStamps -XX:+PrintGCDateStamps -XX:+PrintGCDetails \
      -Xloggc:gc_log.log -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      MarkDuplicatesSpark \
      -I ${sep=' -I 'input_bams} \
      -O ${output_bam_basename}.bam \
      -OBI true \
      -VS SILENT \
      --optical-duplicate-pixel-distance 2500 \
      --conf 'spark.local.dir=/tmp/genomics_temp/' \
      --conf 'spark.executor.cores=2' \
      --conf '--executor-memory=10G' \
      --conf '--num-executors=8' \
      --spark-master local[16]
  >>>
  
      #--executor-memory 5G --executor-cores 2 --num-executors 8 \
  runtime {
    memory: memory
    cpu: cpu
#    backend: "SLURM-MD"
  }
  output {
    File output_bam_index = "${output_bam_basename}.bam.bai"
    File output_bam = "${output_bam_basename}.bam"
  }
}
#command <<<
# 238     set -o pipefail
#  239     set -e
#   240     ${tool_path}/samtools-1.9/samtools sort -T $TMPDIR/${output_bam_basename}.bam.tmp -m ${mem_limit} --threads ${samtools_threads} -l ${compres     sion_level} ${input_bam} -o ${output_bam_basename}.bam
#    241     ${tool_path}/samtools-1.9/samtools index ${output_bam_basename}.bam ${output_bam_basename}.bai
#     242   >>>
#      243   runtime {
#       244     cpu: cpu
#        245     memory: memory
#         246   }
#          247   output {
#           248     File output_bam = "${output_bam_basename}.bam"
#            249     File output_bam_index = "${output_bam_basename}.bai"
#             250 #    File output_bam_md5 = "${output_bam_basename}.bam.md5"
#
# Generate sets of intervals for scatter-gathering over chromosomes
task CreateSequenceGroupingTSV {
  File ref_dict
  String memory
  Int cpu

  # Use python to create the Sequencing Groupings used for BQSR and PrintReads Scatter.
  # It outputs to stdout where it is parsed into a wdl Array[Array[String]]
  # e.g. [["1"], ["2"], ["3", "4"], ["5"], ["6", "7", "8"]]
  command <<<
    python <<CODE
    with open("${ref_dict}", "r") as ref_dict_file:
        sequence_tuple_list = []
        longest_sequence = 0
        for line in ref_dict_file:
            if line.startswith("@SQ"):
                line_split = line.split("\t")
                # (Sequence_Name, Sequence_Length)
                sequence_tuple_list.append((line_split[1].split("SN:")[1], int(line_split[2].split("LN:")[1])))
        longest_sequence = sorted(sequence_tuple_list, key=lambda x: x[1], reverse=True)[0][1]
    # We are adding this to the intervals because hg38 has contigs named with embedded colons and a bug in GATK strips off
    # the last element after a :, so we add this as a sacrificial element.
    hg38_protection_tag = ":1+"
    # initialize the tsv string with the first sequence
    tsv_string = sequence_tuple_list[0][0] + hg38_protection_tag
    temp_size = sequence_tuple_list[0][1]
    for sequence_tuple in sequence_tuple_list[1:]:
        if temp_size + sequence_tuple[1] <= longest_sequence:
            temp_size += sequence_tuple[1]
            tsv_string += "\t" + sequence_tuple[0] + hg38_protection_tag
        else:
            tsv_string += "\n" + sequence_tuple[0] + hg38_protection_tag
            temp_size = sequence_tuple[1]
    # add the unmapped sequences as a separate line to ensure that they are recalibrated as well
    with open("sequence_grouping.txt","w") as tsv_file:
      tsv_file.write(tsv_string)
      tsv_file.close()

    tsv_string += '\n' + "unmapped"

    with open("sequence_grouping_with_unmapped.txt","w") as tsv_file_with_unmapped:
      tsv_file_with_unmapped.write(tsv_string)
      tsv_file_with_unmapped.close()
    CODE
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    Array[Array[String]] sequence_grouping = read_tsv("sequence_grouping.txt")
    Array[Array[String]] sequence_grouping_with_unmapped = read_tsv("sequence_grouping_with_unmapped.txt")
  }
}

# Generate Base Quality Score Recalibration (BQSR) model
task BaseRecalibrator {
  File input_bam
  File input_bam_index
  String recalibration_report_filename
  Array[String] sequence_group_interval
  File dbSNP_vcf
  File dbSNP_vcf_index
  Array[File] known_indels_sites_VCFs
  Array[File] known_indels_sites_indices
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -XX:+PrintFlagsFinal \
      -XX:+PrintGCTimeStamps -XX:+PrintGCDateStamps -XX:+PrintGCDetails \
      -Xloggc:gc_log.log -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      BaseRecalibrator \
      -R ${ref_fasta} \
      -I ${input_bam} \
      --use-original-qualities \
      -O ${recalibration_report_filename} \
      --known-sites ${dbSNP_vcf} \
      --known-sites ${sep=" --known-sites " known_indels_sites_VCFs} \
      -L ${sep=" -L " sequence_group_interval}
  >>>
  runtime {
    memory: memory
    cpu: cpu
    #backend: "SLURM-MID"
  }
  output {
    File recalibration_report = "${recalibration_report_filename}"
  }
}

# Apply Base Quality Score Recalibration (BQSR) model
task ApplyBQSR {
  File input_bam
  File input_bam_index
  String output_bam_basename
  File recalibration_report
  Array[String] sequence_group_interval
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-XX:+PrintFlagsFinal -XX:+PrintGCTimeStamps -XX:+PrintGCDateStamps \
      -XX:+PrintGCDetails -Xloggc:gc_log.log \
      -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      ApplyBQSR \
      --create-output-bam-md5 \
      --add-output-sam-program-record \
      -R ${ref_fasta} \
      -I ${input_bam} \
      --use-original-qualities \
      -O ${output_bam_basename}.bam \
      -bqsr ${recalibration_report} \
      --static-quantized-quals 10 --static-quantized-quals 20 --static-quantized-quals 30 \
      -L ${sep=" -L " sequence_group_interval}
  >>>
  runtime {
    memory: memory
    cpu: cpu
    #backend: "SLURM-MID"
  }
  output {
    File recalibrated_bam = "${output_bam_basename}.bam"
    File recalibrated_bam_checksum = "${output_bam_basename}.bam.md5"
  }
}

# Combine multiple recalibration tables from scattered BaseRecalibrator runs
task GatherBqsrReports {
  Array[File] input_bqsr_reports
  String output_report_filename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      GatherBQSRReports \
      -I ${sep=' -I ' input_bqsr_reports} \
      -O ${output_report_filename}
    >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_bqsr_report = "${output_report_filename}"
  }
}

# Combine multiple recalibrated BAM files from scattered ApplyRecalibration runs
task GatherBamFiles {
  Array[File] input_bams
  String output_bam_basename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      GatherBamFiles \
      INPUT=${sep=' INPUT=' input_bams} \
      OUTPUT=${output_bam_basename}.bam \
      CREATE_INDEX=true \
      CREATE_MD5_FILE=true
    }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_bam = "${output_bam_basename}.bam"
    File output_bam_index = "${output_bam_basename}.bai"
    File output_bam_md5 = "${output_bam_basename}.bam.md5"
  }
}

task ValidateSamFile {
  File input_bam
  File? input_bam_index
  String report_filename
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  Int? max_output
  Array[String]? ignore
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      ValidateSamFile \
      INPUT=${input_bam} \
      OUTPUT=${report_filename} \
      REFERENCE_SEQUENCE=${ref_fasta} \
      ${"MAX_OUTPUT=" + max_output} \
      IGNORE=${default="null" sep=" IGNORE=" ignore} \
      MODE=VERBOSE \
      IS_BISULFITE_SEQUENCED=false
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File report = "${report_filename}"
  }
}

# Note these tasks will break if the read lengths in the bam are greater than 250.
task CollectWgsMetrics {
  File input_bam
  File input_bam_index
  String metrics_filename
  File wgs_coverage_interval_list
  File ref_fasta
  File ref_fasta_index
  Int read_length = 250
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectWgsMetrics \
      INPUT=${input_bam} \
      VALIDATION_STRINGENCY=SILENT \
      REFERENCE_SEQUENCE=${ref_fasta} \
      INCLUDE_BQ_HISTOGRAM=true \
      INTERVALS=${wgs_coverage_interval_list} \
      OUTPUT=${metrics_filename} \
      USE_FAST_ALGORITHM=true \
      READ_LENGTH=${read_length}
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File metrics = "${metrics_filename}"
  }
}

# Collect raw WGS metrics (commonly used QC thresholds)
task CollectRawWgsMetrics {
  File input_bam
  File input_bam_index
  String metrics_filename
  File wgs_coverage_interval_list
  File ref_fasta
  File ref_fasta_index
  Int read_length = 250
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}  -jar ${tool_path}/picard.jar \
      CollectRawWgsMetrics \
      INPUT=${input_bam} \
      VALIDATION_STRINGENCY=SILENT \
      REFERENCE_SEQUENCE=${ref_fasta} \
      INCLUDE_BQ_HISTOGRAM=true \
      INTERVALS=${wgs_coverage_interval_list} \
      OUTPUT=${metrics_filename} \
      USE_FAST_ALGORITHM=true \
      READ_LENGTH=${read_length}
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File metrics = "${metrics_filename}"
  }
}

# Generate a checksum per readgroup
task CalculateReadGroupChecksum {
  File input_bam
  File input_bam_index
  String read_group_md5_filename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CalculateReadGroupChecksum \
      INPUT=${input_bam} \
      OUTPUT=${read_group_md5_filename}
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File md5_file = "${read_group_md5_filename}"
  }
}

# Notes on the contamination estimate:
# The contamination value is read from the FREEMIX field of the selfSM file output by verifyBamId
#
# In Zamboni production, this value is stored directly in METRICS.AGGREGATION_CONTAM
#
# Contamination is also stored in GVCF_CALLING and thereby passed to HAPLOTYPE_CALLER
# But first, it is divided by an underestimation factor thusly:
#   float(FREEMIX) / ContaminationUnderestimationFactor
#     where the denominator is hardcoded in Zamboni:
#     val ContaminationUnderestimationFactor = 0.75f
#
# Here, I am handling this by returning both the original selfSM file for reporting, and the adjusted
# contamination estimate for use in variant calling
task CheckContamination {
  File input_bam
  File input_bam_index
  File contamination_sites_ud
  File contamination_sites_bed
  File contamination_sites_mu
  File ref_fasta
  File ref_fasta_index
  String output_prefix
  Float contamination_underestimation_factor
  String memory
  Int cpu
  String tool_path
  
  command <<<
    set -e

    # creates a ${output_prefix}.selfSM file, a TSV file with 2 rows, 19 columns.
    # First row are the keys (e.g., SEQ_SM, RG, FREEMIX), second row are the associated values
    #/usr/gitc/VerifyBamID \
    ${tool_path}/VerifyBamID/VerifyBamID \
    --Verbose \
    --NumPC 4 \
    --Output ${output_prefix} \
    --BamFile ${input_bam} \
    --Reference ${ref_fasta} \
    --UDPath ${contamination_sites_ud} \
    --MeanPath ${contamination_sites_mu} \
    --BedPath ${contamination_sites_bed} \
    1>/dev/null

    # used to read from the selfSM file and calculate contamination, which gets printed out
    python3 <<CODE
    import csv
    import sys
    with open('${output_prefix}.selfSM') as selfSM:
      reader = csv.DictReader(selfSM, delimiter='\t')
      i = 0
      for row in reader:
        if float(row["FREELK0"])==0 and float(row["FREELK1"])==0:
          # a zero value for the likelihoods implies no data. This usually indicates a problem rather than a real event.
          # if the bam isn't really empty, this is probably due to the use of a incompatible reference build between
          # vcf and bam.
          sys.stderr.write("Found zero likelihoods. Bam is either very-very shallow, or aligned to the wrong reference (relative to the vcf).")
          sys.exit(1)
        print(float(row["FREEMIX"])/${contamination_underestimation_factor})
        i = i + 1
        # there should be exactly one row, and if this isn't the case the format of the output is unexpectedly different
        # and the results are not reliable.
        if i != 1:
          sys.stderr.write("Found %d rows in .selfSM file. Was expecting exactly 1. This is an error"%(i))
          sys.exit(2)
    CODE
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File selfSM = "${output_prefix}.selfSM"
    Float contamination = read_float(stdout())
  }
}

# This task calls picard's IntervalListTools to scatter the input interval list into scatter_count sub interval lists
# Note that the number of sub interval lists may not be exactly equal to scatter_count.  There may be slightly more or less.
# Thus we have the block of python to count the number of generated sub interval lists.
task ScatterIntervalList {
  File interval_list
  Int scatter_count
  Int break_bands_at_multiples_of
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    set -e
    mkdir out
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      IntervalListTools \
      SCATTER_COUNT=${scatter_count} \
      SUBDIVISION_MODE=BALANCING_WITHOUT_INTERVAL_SUBDIVISION_WITH_OVERFLOW \
      UNIQUE=true \
      SORT=true \
      BREAK_BANDS_AT_MULTIPLES_OF=${break_bands_at_multiples_of} \
      INPUT=${interval_list} \
      OUTPUT=out

    python3 <<CODE
    import glob, os
    # Works around a JES limitation where multiples files with the same name overwrite each other when globbed
    intervals = sorted(glob.glob("out/*/*.interval_list"))
    for i, interval in enumerate(intervals):
      (directory, filename) = os.path.split(interval)
      newName = os.path.join(directory, str(i + 1) + filename)
      os.rename(interval, newName)
    print(len(intervals))
    CODE
  >>>
  output {
    Array[File] out = glob("out/*/*.interval_list")
    Int interval_count = read_int(stdout())
  }
  runtime {
    memory: memory
    cpu: cpu
  }
}

# Call variants on a single sample with HaplotypeCaller to produce a GVCF
task HaplotypeCaller {
  File input_bam
  File input_bam_index
  File interval_list
  String gvcf_basename
  File ref_dict
  File ref_fasta
  File ref_fasta_index
  Float? contamination
  String gatk_gkl_pairhmm_implementation
  Int gatk_gkl_pairhmm_threads
  Int compression_level
  String haplotypecaller_java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  String smith_waterman_implementation
  
  # We use interval_padding 500 below to make sure that the HaplotypeCaller has context on both sides around
  # the interval because the assembly uses them.
  command <<<
      export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
      ${tool_path}/gatk-4.1.4.0/gatk --java-options -Xmx${haplotypecaller_java_heap_memory_initial} \
      HaplotypeCaller \
      -R ${ref_fasta} \
      -I ${input_bam} \
      -O ${gvcf_basename}.vcf.gz \
      -L ${interval_list} \
      -ip 100 \
      -contamination ${default=0 contamination} \
      --max-alternate-alleles 3 \
      -ERC GVCF \
      --pair-hmm-implementation ${gatk_gkl_pairhmm_implementation} \
      --native-pair-hmm-threads ${gatk_gkl_pairhmm_threads} \
      --smith-waterman ${smith_waterman_implementation}
  >>>
  runtime {
    memory: memory
    cpu: cpu
    #backend: "SLURM-HAPLO"
    #require_fpga: "yes"
  }
  output {
    File output_gvcf = "${gvcf_basename}.vcf.gz"
    File output_gvcf_index = "${gvcf_basename}.vcf.gz.tbi"
  }
}

# Combine multiple VCFs or GVCFs from scattered HaplotypeCaller runs
task MergeVCFs {
  Array[File] input_vcfs
  Array[File] input_vcfs_indexes
  String output_vcf_name
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  # Using MergeVcfs instead of GatherVcfs so we can create indices
  # See https://github.com/broadinstitute/picard/issues/789 for relevant GatherVcfs ticket
  command <<<
      export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
      ${tool_path}/gatk-4.1.4.0/gatk --java-options -Xmx${java_heap_memory_initial} \
      MergeVcfs \
      --INPUT=${sep=' --INPUT=' input_vcfs} \
      --OUTPUT=${output_vcf_name}
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_vcf = "${output_vcf_name}"
    File output_vcf_index = "${output_vcf_name}.tbi"
  }
}

# Validate a GVCF with -gvcf specific validation
task ValidateGVCF {
  File input_vcf
  File input_vcf_index
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File dbSNP_vcf
  File dbSNP_vcf_index
  File wgs_calling_interval_list
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      ValidateVariants \
      -V ${input_vcf} \
      -R ${ref_fasta} \
      -L ${wgs_calling_interval_list} \
      -gvcf \
      --validationTypeToExclude ALLELES \
      --dbsnp ${dbSNP_vcf}
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
}

task AddReadGroup {
  File input_bam
  String output_bam_basename
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  String read_group
  String sample_name
  String LB_name
  
  # The program default for READ_NAME_REGEX is appropriate in nearly every case.
  # Sometimes we wish to supply "null" in order to turn off optical duplicate detection
  # This can be desirable if you don't mind the estimated library size being wrong and optical duplicate detection is taking >7 days and failing

 # Task is assuming query-sorted input so that the Secondary and Supplementary reads get marked correctly
 # This works because the output of BWA is query-grouped and therefore, so is the output of MergeBamAlignment.
 # While query-grouped isn't actually query-sorted, it's good enough for MarkDuplicates with ASSUME_SORT_ORDER="queryname"
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      AddOrReplaceReadGroups \
      INPUT=${input_bam}\
      OUTPUT=${output_bam_basename}.bam \
	  SORT_ORDER=coordinate \
	  RGID=${sample_name} RGLB=${LB_name} RGPL=illumina RGPU=${read_group} RGSM=${sample_name}
      VALIDATION_STRINGENCY=SILENT
	  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_bam = "${output_bam_basename}.bam"
  }
}

task GVCFtoVCF {
  File input_vcf
  File input_vcf_index
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  String output_vcf_name
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command <<<
    export GATK_LOCAL_JAR=${tool_path}/gatk-4.1.4.0/gatk-package-4.1.4.0-local.jar && \
    ${tool_path}/gatk-4.1.4.0/gatk --java-options "-Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial}" \
      GenotypeGVCFs  \
      -V ${input_vcf} \
      -R ${ref_fasta} \
      -O ${output_vcf_name}.vcf.gz
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_finalvcf = "${output_vcf_name}.vcf.gz"
}
}


# Collect variant calling metrics from GVCF output
task CollectGvcfCallingMetrics {
  File input_vcf
  File input_vcf_index
  String metrics_basename
  File dbSNP_vcf
  File dbSNP_vcf_index
  File ref_dict
  File wgs_evaluation_interval_list
  Int compression_level
  String java_heap_memory_initial
  String memory
  Int cpu
  String tool_path
  
  command {
    java -Dsamjdk.compression_level=${compression_level} -Xmx${java_heap_memory_initial} -jar ${tool_path}/picard.jar \
      CollectVariantCallingMetrics \
      INPUT=${input_vcf} \
      OUTPUT=${metrics_basename} \
      DBSNP=${dbSNP_vcf} \
      SEQUENCE_DICTIONARY=${ref_dict} \
      TARGET_INTERVALS=${wgs_evaluation_interval_list} \
      GVCF_INPUT=true
  }
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File summary_metrics = "${metrics_basename}.variant_calling_summary_metrics"
    File detail_metrics = "${metrics_basename}.variant_calling_detail_metrics"
  }
}

# Convert BAM file to CRAM format
# Note that reading CRAMs directly with Picard is not yet supported
task ConvertToCram {
  File input_bam
  File ref_fasta
  File ref_fasta_index
  String output_basename
  String memory
  Int cpu
  String tool_path
  
  command <<<
    set -e
    set -o pipefail

    ${tool_path}/samtools-1.9/samtools view -C -T ${ref_fasta} ${input_bam} | \
    tee ${output_basename}.cram | \
    md5sum | awk '{print $1}' > ${output_basename}.cram.md5

    # Create REF_CACHE. Used when indexing a CRAM
    ${tool_path}/seq_cache_populate.pl -root ./ref/cache ${ref_fasta}
    export REF_PATH=:
    export REF_CACHE=./ref/cache/%2s/%2s/%s

    ${tool_path}/samtools-1.9/samtools index ${output_basename}.cram
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_cram = "${output_basename}.cram"
    File output_cram_index = "${output_basename}.cram.crai"
    File output_cram_md5 = "${output_basename}.cram.md5"
  }
}

# Convert a CRAM file to BAM format for validation purposes
task CramToBam {
  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File cram_file
  String output_basename
  String memory
  Int cpu
  String tool_path
  
  command <<<
    set -e
    set -o pipefail

    ${tool_path}/samtools-1.9/samtools view -h -T ${ref_fasta} ${cram_file} |
    ${tool_path}/samtools-1.9/samtools view -b -o ${output_basename}.bam -
    ${tool_path}/samtools-1.9/samtools index -b ${output_basename}.bam
    mv ${output_basename}.bam.bai ${output_basename}.bai
  >>>
  runtime {
    memory: memory
    cpu: cpu
  }
  output {
    File output_bam = "${output_basename}.bam"
    File output_bam_index = "${output_basename}.bai"
  }
}

# Calculates sum of a list of floats
task SumFloats {
  Array[Float] sizes

  command <<<
  python -c "print ${sep="+" sizes}"
  >>>
  output {
    Float total_size = read_float(stdout())
  }
  runtime {
  }
}

# WORKFLOW DEFINITION
workflow PairedEndSingleSampleWorkflow {

  File contamination_sites_ud
  File contamination_sites_bed
  File contamination_sites_mu
  File? fingerprint_genotypes_file
  File? haplotype_database_file
  File wgs_evaluation_interval_list
  File wgs_coverage_interval_list
 

  String sample_name
  String base_file_name
  String final_gvcf_name
  Array[File] flowcell_unmapped_bams
  Array[File] flowcell_unmapped_fastqs
  String unmapped_bam_suffix

  File wgs_calling_interval_list
  Int haplotype_scatter_count
  Int break_bands_at_multiples_of
  Int? read_length

  File ref_fasta
  File ref_fasta_index
  File ref_dict
  File ref_alt
  File ref_bwt
  File ref_sa
  File ref_amb
  File ref_ann
  File ref_pac
  String LB_name
  String read_group
  
  File dbSNP_vcf
  File dbSNP_vcf_index
  Array[File] known_indels_sites_VCFs
  Array[File] known_indels_sites_indices

  # Optional input to increase all disk sizes in case of outlier sample with strange size behavior
  Int? increase_disk_size

  # Some input files can be less than 1GB, therefore we need to add 1 to prevent getting a cromwell error when asking for 0 disk
  Int small_additional_disk = select_first([increase_disk_size, 1])
  # Some tasks need more wiggle room than a single GB when the input bam is small
  Int medium_additional_disk = select_first([increase_disk_size, 5])
  # Germline single sample GVCFs shouldn't get bigger even when the input bam is bigger (after a certain size)
  Int GVCF_disk_size = select_first([increase_disk_size, 30])
  # Sometimes the output is larger than the input, or a task can spill to disk. In these cases we need to account for the 
  # input (1) and the output (1.5) or the input(1), the output(1), and spillage (.5).
  Float bwa_disk_multiplier = 2.5
  # SortSam spills to disk a lot more because we are only store 300000 records in RAM now because its faster for our data
  # so it needs more disk space.  Also it spills to disk in an uncompressed format so we need to account for that with a
  # larger multiplier
  Float sort_sam_disk_multiplier = 3.25

  # Mark Duplicates takes in as input readgroup bams and outputs a slightly smaller aggregated bam. Giving .25 as wiggleroom
  Float md_disk_multiplier = 2.25

  # Path to tools
  String tool_path
  
  #Optimization flags
  Int bwa_threads
  Int samtools_threads
  Int compression_level
  String gatk_gkl_pairhmm_implementation
  Int gatk_gkl_pairhmm_threads

  String bwa_commandline="bwa/bwa mem -K 100000000 -p -v 3 -t $bwa_threads -Y $bash_ref_fasta"

  String recalibrated_bam_basename = base_file_name + ".aligned.duplicates_marked.recalibrated"

  # Get the version of BWA to include in the PG record in the header of the BAM produced
  # by MergeBamAlignment.
  call GetBwaVersion {
     input: 
	    tool_path = tool_path
  }

  # Check that the GVCF output name follows convention
  call CheckFinalVcfExtension {
     input:
        vcf_filename = final_gvcf_name
   }

  # Get the size of the standard reference files as well as the additional reference files needed for BWA
  Float ref_size = size(ref_fasta, "GB") + size(ref_fasta_index, "GB") + size(ref_dict, "GB")
  Float bwa_ref_size = ref_size + size(ref_alt, "GB") + size(ref_amb, "GB") + size(ref_ann, "GB") + size(ref_bwt, "GB") + size(ref_pac, "GB") + size(ref_sa, "GB")
  Float dbsnp_size = size(dbSNP_vcf, "GB")

  # Align flowcell-level unmapped input bams in parallel
  scatter (unmapped_fastq in flowcell_unmapped_fastqs) {

    Float unmapped_fastq_size = size(unmapped_fastq, "GB")
    
	#Change the path below to where your files reside in your shared file system. 
	String sub_strip_path = "/genomics/genomics/data/.*/"
    String sub_strip_unmapped = unmapped_bam_suffix + "$"
    String sub_sub = sub(sub(unmapped_fastq, sub_strip_path, ""), sub_strip_unmapped, "")

    # QC the unmapped BAM
    #call CollectQualityYieldMetrics {
    #  input:
	#    input_bam = unmapped_bam,
    #    metrics_filename = sub_sub + ".unmapped.quality_yield_metrics",
	#    tool_path = tool_path
    #}
    call GetFastqName {
     input: 
	    unmapped_fastq = unmapped_fastq
  }
    # Map reads to reference
    call SamToFastqAndBwaMemAndMba {
      input:
        bwa_commandline = bwa_commandline,
        output_bam_basename = sub_sub + ".aligned.unsorted",
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        ref_dict = ref_dict,
        ref_alt = ref_alt,
        ref_bwt = ref_bwt,
        ref_amb = ref_amb,
        ref_ann = ref_ann,
        ref_pac = ref_pac,
        ref_sa = ref_sa,
        bwa_version = GetBwaVersion.version,
		#SampleName = SampleName,
		FastqName = GetFastqName.FastqName,
        # The merged bam can be bigger than only the aligned bam,
        # so account for the output size by multiplying the input size by 2.75.
        #disk_size = unmapped_bam_size + bwa_ref_size + (bwa_disk_multiplier * unmapped_bam_size) + small_additional_disk,
        compression_level = compression_level,
        bwa_threads = bwa_threads,
		tool_path = tool_path
    }
	 call AddReadGroup {
    input:
      input_bam = SamToFastqAndBwaMemAndMba.output_bam,
      output_bam_basename = sub_sub + ".aligned.unsorted.ARRG",
      # The merged bam will be smaller than the sum of the parts so we need to account for the unmerged inputs
      # and the merged output.
      #disk_size = (md_disk_multiplier * SumFloats.total_size) + small_additional_disk,
      compression_level = compression_level,
	  tool_path = tool_path,
	  sample_name = sample_name,
      LB_name = LB_name,
	  read_group = read_group
    }
	
	
    #Float mapped_bam_size = size(SortSampleBam.output_bam, "GB")

    # QC the aligned but unsorted readgroup BAM
    # no reference as the input here is unsorted, providing a reference would cause an error
    #call CollectUnsortedReadgroupBamQualityMetrics {
    #  input:
    #    input_bam = SamToFastqAndBwaMemAndMba.output_bam,
    #    output_bam_prefix = sub_sub + ".readgroup",
	#     tool_path = tool_path
    #}
  

  # Sum the read group bam sizes to approximate the aggregated bam size
  #call SumFloats {
  #  input:
  #    sizes = mapped_bam_size
  #}

  # Aggregate aligned+merged flowcell BAM files and mark duplicates
  # We take advantage of the tool's ability to take multiple BAM inputs and write out a single output
  # to avoid having to spend time just merging BAM files.

	    Float agg_bam_size = size(AddReadGroup.output_bam, "GB")

}

 call MarkDuplicatesSpark {
    input:
      input_bams = AddReadGroup.output_bam,
      output_bam_basename = base_file_name + ".aligned.duplicates_marked.sorted",
      metrics_filename = base_file_name + ".duplicate_metrics",
      # The merged bam will be smaller than the sum of the parts so we need to account for the unmerged inputs
      # and the merged output.
      #disk_size = (md_disk_multiplier * SumFloats.total_size) + small_additional_disk,
      compression_level = compression_level,
	  tool_path = tool_path
  }


  # Sort aggregated+deduped BAM file and fix tags
 

  if (defined(haplotype_database_file)) {
    #Check identity of fingerprints across readgroups
    call CrossCheckFingerprints {
               input:
                      input_bams =  MarkDuplicatesSpark.output_bam,
                      input_bam_indexes =  MarkDuplicatesSpark.output_bam_index,
                      haplotype_database_file = haplotype_database_file,
		      metrics_filename = sample_name + ".crosscheck",
                      tool_path = tool_path
    }
  }
                                                                    

      #  input_bam_indexes = SortSampleBam.output_bam_index,
      #  input_bams =  MarkDuplicatesSpark.output_bam,
      #  input_bams_indexes = MarkDuplicatesSpark.output_bam_index,

  # Create list of sequences for scatter-gather parallelization
  call CreateSequenceGroupingTSV {
    input:
      ref_dict = ref_dict
  }

  # Estimate level of cross-sample contamination
  #call CheckContamination {
  #  input:
  #    input_bam = SortSampleBam.output_bam,
  #    input_bam_index = SortSampleBam.output_bam_index,
  #    contamination_sites_ud = contamination_sites_ud,
  #    contamination_sites_bed = contamination_sites_bed,
  #    contamination_sites_mu = contamination_sites_mu,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    output_prefix = base_file_name + ".preBqsr",
  #    contamination_underestimation_factor = 0.75,
	#  tool_path = tool_path
  #}

  # We need disk to localize the sharded input and output due to the scatter for BQSR.
  # If we take the number we are scattering by and reduce by 3 we will have enough disk space
  # to account for the fact that the data is not split evenly.
  Int num_of_bqsr_scatters = length(CreateSequenceGroupingTSV.sequence_grouping)
  Int potential_bqsr_divisor = num_of_bqsr_scatters - 3
  Int bqsr_divisor = if potential_bqsr_divisor > 1 then potential_bqsr_divisor else 1

  # Perform Base Quality Score Recalibration (BQSR) on the sorted BAM in parallel
  scatter (subgroup in CreateSequenceGroupingTSV.sequence_grouping) {
    # Generate the recalibration model by interval
    call BaseRecalibrator {
      input:
        #input_bam = SortSampleBam.output_bam,
        #input_bam_index = SortSampleBam.output_bam_index,
        input_bam =  MarkDuplicatesSpark.output_bam,
        input_bam_index = MarkDuplicatesSpark.output_bam_index,
        recalibration_report_filename = base_file_name + ".recal_data.csv",
        sequence_group_interval = subgroup,
        dbSNP_vcf = dbSNP_vcf,
        dbSNP_vcf_index = dbSNP_vcf_index,
        known_indels_sites_VCFs = known_indels_sites_VCFs,
        known_indels_sites_indices = known_indels_sites_indices,
        ref_dict = ref_dict,
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        # We need disk to localize the sharded bam due to the scatter.
        #disk_size = (agg_bam_size / bqsr_divisor) + ref_size + dbsnp_size + small_additional_disk,
        compression_level = compression_level,
		tool_path = tool_path
    }
  }

  # Merge the recalibration reports resulting from by-interval recalibration
  # The reports are always the same size
  call GatherBqsrReports {
    input:
      input_bqsr_reports = BaseRecalibrator.recalibration_report,
      output_report_filename = base_file_name + ".recal_data.csv",
      compression_level = compression_level,
	  tool_path = tool_path
  }

  scatter (subgroup in CreateSequenceGroupingTSV.sequence_grouping_with_unmapped) {
    # Apply the recalibration model by interval
    call ApplyBQSR {
      input:
#        input_bam = SortSampleBam.output_bam,
#        input_bam_index = SortSampleBam.output_bam_index,
        input_bam = MarkDuplicatesSpark.output_bam,
        input_bam_index = MarkDuplicatesSpark.output_bam_index,

        output_bam_basename = recalibrated_bam_basename,
        recalibration_report = GatherBqsrReports.output_bqsr_report,
        sequence_group_interval = subgroup,
        ref_dict = ref_dict,
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        # We need disk to localize the sharded bam and the sharded output due to the scatter.
        #disk_size = ((agg_bam_size + agg_bam_size) / bqsr_divisor) + ref_size + small_additional_disk,
        compression_level = compression_level,
		tool_path = tool_path
    }
  }

  # Merge the recalibrated BAM files resulting from by-interval recalibration
  call GatherBamFiles {
    input:
      input_bams = ApplyBQSR.recalibrated_bam,
      output_bam_basename = base_file_name,
      # Multiply the input bam size by two to account for the input and output
      #disk_size = (2 * agg_bam_size) + small_additional_disk,
      compression_level = compression_level,
	  tool_path = tool_path
  }

  #BQSR bins the qualities which makes a significantly smaller bam
  Float binned_qual_bam_size = size(GatherBamFiles.output_bam, "GB")

  # QC the final BAM (consolidated after scattered BQSR)
  #call CollectReadgroupBamQualityMetrics {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    input_bam_index = GatherBamFiles.output_bam_index,
  #    output_bam_prefix = base_file_name + ".readgroup",
  #    ref_dict = ref_dict,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    tool_path = tool_path
  #}

  # QC the final BAM some more (no such thing as too much QC)
  #call CollectAggregationMetrics {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    input_bam_index = GatherBamFiles.output_bam_index,
  #    output_bam_prefix = base_file_name,
  #    ref_dict = ref_dict,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    tool_path = tool_path
  #}

  if (defined(haplotype_database_file) && defined(fingerprint_genotypes_file)) {
    # Check the sample BAM fingerprint against the sample array
    call CheckFingerprint {
      input:
        input_bam = GatherBamFiles.output_bam,
        input_bam_index = GatherBamFiles.output_bam_index,
        haplotype_database_file = haplotype_database_file,
        genotypes = fingerprint_genotypes_file,
        output_basename = base_file_name,
        sample = sample_name,
		tool_path = tool_path
    }
  }

  # QC the sample WGS metrics (stringent thresholds)
  #call CollectWgsMetrics {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    input_bam_index = GatherBamFiles.output_bam_index,
  #    metrics_filename = base_file_name + ".wgs_metrics",
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    wgs_coverage_interval_list = wgs_coverage_interval_list,
  #    read_length = read_length,
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}

  # QC the sample raw WGS metrics (common thresholds)
  #call CollectRawWgsMetrics {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    input_bam_index = GatherBamFiles.output_bam_index,
  #    metrics_filename = base_file_name + ".raw_wgs_metrics",
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    wgs_coverage_interval_list = wgs_coverage_interval_list,
  #    read_length = read_length,
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}

  # Generate a checksum per readgroup in the final BAM
  #call CalculateReadGroupChecksum {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    input_bam_index = GatherBamFiles.output_bam_index,
  #    read_group_md5_filename = recalibrated_bam_basename + ".bam.read_group_md5",
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}

  # Convert the final merged recalibrated BAM file to CRAM format
  #call ConvertToCram {
  #  input:
  #    input_bam = GatherBamFiles.output_bam,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    output_basename = base_file_name,
  #    tool_path = tool_path
      # We need more wiggle room for small samples (for example if binned_qual_bam_size is < 1) and
      # multiplying the input size by 2 to account for the output cram.
      #disk_size = (2 * binned_qual_bam_size) + ref_size + medium_additional_disk,
  #}

  #Float cram_size = size(ConvertToCram.output_cram, "GB")

  # Convert the CRAM back to BAM to check that the conversions do not introduce errors
  #call CramToBam {
  #  input:
  #    ref_fasta = ref_fasta,
  #    ref_dict = ref_dict,
  #    ref_fasta_index = ref_fasta_index,
  #    cram_file = ConvertToCram.output_cram,
  #    output_basename = base_file_name + ".roundtrip",
  #    tool_path = tool_path
  #}

  # Validate the roundtripped BAM
  #call ValidateSamFile as ValidateBamFromCram {
  #  input:
  #    input_bam = CramToBam.output_bam,
  #    input_bam_index = CramToBam.output_bam_index,
  #    report_filename = base_file_name + ".bam.roundtrip.validation_report",
  #    ref_dict = ref_dict,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    max_output = 1000000000,
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}

  # Break the calling interval_list into sub-intervals
  # Perform variant calling on the sub-intervals, and then gather the results
  call ScatterIntervalList {
    input:
      interval_list = wgs_calling_interval_list,
      scatter_count = haplotype_scatter_count,
      break_bands_at_multiples_of = break_bands_at_multiples_of,
      compression_level = compression_level,
	  tool_path = tool_path
  }

  # We need disk to localize the sharded input and output due to the scatter for HaplotypeCaller.
  # If we take the number we are scattering by and reduce by 20 we will have enough disk space
  # to account for the fact that the data is quite uneven across the shards.
  Int potential_hc_divisor = ScatterIntervalList.interval_count - 20
  Int hc_divisor = if potential_hc_divisor > 1 then potential_hc_divisor else 1

  # Call variants in parallel over WGS calling intervals
  scatter (index in range(ScatterIntervalList.interval_count)) {
    # Generate GVCF by interval
    call HaplotypeCaller {
      input:
        #contamination = CheckContamination.contamination,
        input_bam = GatherBamFiles.output_bam,
        input_bam_index = GatherBamFiles.output_bam_index,
        interval_list = ScatterIntervalList.out[index],
        gvcf_basename = sample_name,
        ref_dict = ref_dict,
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        # Divide the total output GVCF size and the input bam size to account for the smaller scattered input and output.
        #disk_size = ((binned_qual_bam_size + GVCF_disk_size) / hc_divisor) + ref_size + small_additional_disk,
        compression_level = compression_level, 
        gatk_gkl_pairhmm_implementation = gatk_gkl_pairhmm_implementation, 
        gatk_gkl_pairhmm_threads = gatk_gkl_pairhmm_threads,
        tool_path = tool_path
     }
  }

  # Combine by-interval GVCFs into a single sample GVCF file
  call MergeVCFs {
    input:
      input_vcfs = HaplotypeCaller.output_gvcf,
      input_vcfs_indexes = HaplotypeCaller.output_gvcf_index,
      output_vcf_name = final_gvcf_name,
      compression_level = compression_level,
	  tool_path = tool_path
  }

  #Float gvcf_size = size(MergeVCFs.output_vcf, "GB")

  # Validate the GVCF output of HaplotypeCaller
  #call ValidateGVCF {
  #  input:
  #    input_vcf = MergeVCFs.output_vcf,
  #    input_vcf_index = MergeVCFs.output_vcf_index,
  #    dbSNP_vcf = dbSNP_vcf,
  #    dbSNP_vcf_index = dbSNP_vcf_index,
  #    ref_fasta = ref_fasta,
  #    ref_fasta_index = ref_fasta_index,
  #    ref_dict = ref_dict,
  #    wgs_calling_interval_list = wgs_calling_interval_list,
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}


  call GVCFtoVCF {
    input:
      input_vcf = MergeVCFs.output_vcf,
	  input_vcf_index = MergeVCFs.output_vcf_index,
      ref_fasta = ref_fasta,
	  ref_dict = ref_dict,
	  ref_fasta_index = ref_fasta_index,
      compression_level = compression_level,
	  output_vcf_name = final_gvcf_name,
      tool_path = tool_path
  }
  
  # QC the GVCF
  #call CollectGvcfCallingMetrics {
  #  input:
  #    input_vcf = MergeVCFs.output_vcf,
  #    input_vcf_index = MergeVCFs.output_vcf_index,
  #    metrics_basename = base_file_name,
  #    dbSNP_vcf = dbSNP_vcf,
  #    dbSNP_vcf_index = dbSNP_vcf_index,
  #    ref_dict = ref_dict,
  #    wgs_evaluation_interval_list = wgs_evaluation_interval_list,
  #    compression_level = compression_level,
  #    tool_path = tool_path
  #}

  # Outputs that will be retained when execution is complete
  output {
    #Array[File] quality_yield_metrics = CollectQualityYieldMetrics.metrics

    #Array[File] unsorted_read_group_base_distribution_by_cycle_pdf = CollectUnsortedReadgroupBamQualityMetrics.base_distribution_by_cycle_pdf
    #Array[File] unsorted_read_group_base_distribution_by_cycle_metrics = CollectUnsortedReadgroupBamQualityMetrics.base_distribution_by_cycle_metrics
    #Array[File] unsorted_read_group_insert_size_histogram_pdf = CollectUnsortedReadgroupBamQualityMetrics.insert_size_histogram_pdf
    #Array[File] unsorted_read_group_insert_size_metrics = CollectUnsortedReadgroupBamQualityMetrics.insert_size_metrics
    #Array[File] unsorted_read_group_quality_by_cycle_pdf = CollectUnsortedReadgroupBamQualityMetrics.quality_by_cycle_pdf
    #Array[File] unsorted_read_group_quality_by_cycle_metrics = CollectUnsortedReadgroupBamQualityMetrics.quality_by_cycle_metrics
    #Array[File] unsorted_read_group_quality_distribution_pdf = CollectUnsortedReadgroupBamQualityMetrics.quality_distribution_pdf
    #Array[File] unsorted_read_group_quality_distribution_metrics = CollectUnsortedReadgroupBamQualityMetrics.quality_distribution_metrics

    #File read_group_alignment_summary_metrics = CollectReadgroupBamQualityMetrics.alignment_summary_metrics
    #File read_group_gc_bias_detail_metrics = CollectReadgroupBamQualityMetrics.gc_bias_detail_metrics
    #File read_group_gc_bias_pdf = CollectReadgroupBamQualityMetrics.gc_bias_pdf
    #File read_group_gc_bias_summary_metrics = CollectReadgroupBamQualityMetrics.gc_bias_summary_metrics

   # File? cross_check_fingerprints_metrics = CrossCheckFingerprints.metrics

    #File selfSM = CheckContamination.selfSM

    #File calculate_read_group_checksum_md5 = CalculateReadGroupChecksum.md5_file

    #File agg_alignment_summary_metrics = CollectAggregationMetrics.alignment_summary_metrics
    #File agg_bait_bias_detail_metrics = CollectAggregationMetrics.bait_bias_detail_metrics
    #File agg_bait_bias_summary_metrics = CollectAggregationMetrics.bait_bias_summary_metrics
    #File agg_gc_bias_detail_metrics = CollectAggregationMetrics.gc_bias_detail_metrics
    #File agg_gc_bias_pdf = CollectAggregationMetrics.gc_bias_pdf
    #File agg_gc_bias_summary_metrics = CollectAggregationMetrics.gc_bias_summary_metrics
    #File agg_insert_size_histogram_pdf = CollectAggregationMetrics.insert_size_histogram_pdf
    #File agg_insert_size_metrics = CollectAggregationMetrics.insert_size_metrics
    #File agg_pre_adapter_detail_metrics = CollectAggregationMetrics.pre_adapter_detail_metrics
    #File agg_pre_adapter_summary_metrics = CollectAggregationMetrics.pre_adapter_summary_metrics
    #File agg_quality_distribution_pdf = CollectAggregationMetrics.quality_distribution_pdf
    #File agg_quality_distribution_metrics = CollectAggregationMetrics.quality_distribution_metrics

    File? fingerprint_summary_metrics = CheckFingerprint.summary_metrics
    File? fingerprint_detail_metrics = CheckFingerprint.detail_metrics

    #File wgs_metrics = CollectWgsMetrics.metrics
    #File raw_wgs_metrics = CollectRawWgsMetrics.metrics

    #File gvcf_summary_metrics = CollectGvcfCallingMetrics.summary_metrics
    #File gvcf_detail_metrics = CollectGvcfCallingMetrics.detail_metrics

#    File duplicate_metrics = MarkDuplicatesSpark.duplicate_metrics
    File output_bqsr_reports = GatherBqsrReports.output_bqsr_report

    #File output_cram = ConvertToCram.output_cram
    #File output_cram_index = ConvertToCram.output_cram_index
    #File output_cram_md5 = ConvertToCram.output_cram_md5

    #File validate_bam_from_cram_file_report = ValidateBamFromCram.report
   
    File output_vcf = MergeVCFs.output_vcf
    File output_vcf_index = MergeVCFs.output_vcf_index
	
File output_finalvcf = GVCFtoVCF.output_finalvcf
  }
}