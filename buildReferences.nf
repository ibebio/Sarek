#!/usr/bin/env nextflow

/*
kate: syntax groovy; space-indent on; indent-width 2;
================================================================================
=                                 S  A  R  E  K                                =
================================================================================
 New Germline (+ Somatic) Analysis Workflow. Started March 2016.
--------------------------------------------------------------------------------
 @Authors
 Sebastian DiLorenzo <sebastian.dilorenzo@bils.se> [@Sebastian-D]
 Jesper Eisfeldt <jesper.eisfeldt@scilifelab.se> [@J35P312]
 Phil Ewels <phil.ewels@scilifelab.se> [@ewels]
 Maxime Garcia <maxime.garcia@scilifelab.se> [@MaxUlysse]
 Szilveszter Juhos <szilveszter.juhos@scilifelab.se> [@szilvajuhos]
 Max Käller <max.kaller@scilifelab.se> [@gulfshores]
 Malin Larsson <malin.larsson@scilifelab.se> [@malinlarsson]
 Marcel Martin <marcel.martin@scilifelab.se> [@marcelm]
 Björn Nystedt <bjorn.nystedt@scilifelab.se> [@bjornnystedt]
 Pall Olason <pall.olason@scilifelab.se> [@pallolason]
--------------------------------------------------------------------------------
 @Homepage
 http://opensource.scilifelab.se/projects/sarek/
--------------------------------------------------------------------------------
 @Documentation
 https://github.com/SciLifeLab/Sarek/README.md
--------------------------------------------------------------------------------
 Processes overview
 - DecompressFile - Extract files if needed
 - BuildBWAindexes - Build indexes for BWA
 - BuildReferenceIndex - Build index for FASTA refs
 - BuildSAMToolsIndex - Build index with SAMTools
 - BuildVCFIndex - Build index for VCF files
================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

if (params.help) exit 0, helpMessage()
if (!SarekUtils.isAllowedParams(params)) exit 1, "params unknown, see --help for more information"
if (!checkUppmaxProject()) exit 1, "No UPPMAX project ID found! Use --project <UPPMAX Project ID>"

ch_referencesFiles = Channel.fromPath("${params.refDir}/*")

/*
================================================================================
=                               P R O C E S S E S                              =
================================================================================
*/

startMessage()

ch_compressedfiles = Channel.create()
ch_notCompressedfiles = Channel.create()

ch_referencesFiles
  .choice(ch_compressedfiles, ch_notCompressedfiles) {it =~ ".(gz|tar.bz2)" ? 0 : 1}

process DecompressFile {
  tag {f_reference}

  input:
    file(f_reference) from ch_compressedfiles

  output:
    file("*.{vcf,fasta,loci}") into ch_decompressedFiles

  script:
  realReferenceFile="readlink ${f_reference}"
  if (f_reference =~ ".gz")
    """
    gzip -d -c \$(${realReferenceFile}) > ${f_reference.baseName}
    """
  else if (f_reference =~ ".tar.bz2")
    """
    tar xvjf \$(${realReferenceFile})
    """
}

if (params.verbose) ch_decompressedFiles = ch_decompressedFiles.view {
  "Files decomprecessed: ${it.fileName}"
}

ch_fastaFile = Channel.create()
ch_fastaForBWA = Channel.create()
ch_fastaReference = Channel.create()
ch_fastaForSAMTools = Channel.create()
ch_otherFile = Channel.create()
ch_vcfFile = Channel.create()

ch_decompressedFiles
  .choice(ch_fastaFile, ch_vcfFile, ch_otherFile) {
    it =~ ".fasta" ? 0 :
    it =~ ".vcf" ? 1 : 2}

(ch_fastaForBWA, ch_fastaReference, ch_fastaForSAMTools, ch_fastaFileToKeep) = ch_fastaFile.into(4)
(ch_vcfFile, ch_vcfFileToKeep) = ch_vcfFile.into(2)

ch_notCompressedfiles
  .mix(ch_fastaFileToKeep, ch_vcfFileToKeep, ch_otherFile)
  .collectFile(storeDir: params.outDir)

process BuildBWAindexes {
  tag {f_reference}

  publishDir params.outDir, mode: 'link'

  input:
    file(f_reference) from ch_fastaForBWA

  output:
    file("*.{amb,ann,bwt,pac,sa}") into bwaIndexes

  script:

  """
  bwa index ${f_reference}
  """
}

if (params.verbose) bwaIndexes.flatten().view {
  "BWA index           : ${it.fileName}"
}

process BuildReferenceIndex {
  tag {f_reference}

  publishDir params.outDir, mode: 'link'

  input:
    file(f_reference) from ch_fastaReference

  output:
    file("*.dict") into ch_referenceIndex

  script:
  """
  gatk --java-options "-Xmx${task.memory.toGiga()}g" \
  CreateSequenceDictionary \
  --REFERENCE ${f_reference} \
  --OUTPUT ${f_reference.baseName}.dict
  """
}

if (params.verbose) ch_referenceIndex.view {
  "Reference index     : ${it.fileName}"
}

process BuildSAMToolsIndex {
  tag {f_reference}

  publishDir params.outDir, mode: 'link'

  input:
    file(f_reference) from ch_fastaForSAMTools

  output:
    file("*.fai") into ch_samtoolsIndex

  script:
  """
  samtools faidx ${f_reference}
  """
}

if (params.verbose) ch_samtoolsIndex.view {
  "SAMTools index      : ${it.fileName}"
}

process BuildVCFIndex {
  tag {f_reference}

  publishDir params.outDir, mode: 'link'

  input:
    file(f_reference) from ch_vcfFile

  output:
    file("${f_reference}.idx") into ch_vcfIndex

  script:
  """
  igvtools index ${f_reference}
  """
}

if (params.verbose) ch_vcfIndex.view {
  "VCF index           : ${it.fileName}"
}

/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def checkFile(it) {
  // Check file existence
  final f = file(it)
  if (!f.exists()) exit 1, "Missing file: ${it}, see --help for more information"
  return true
}

def checkUppmaxProject() {
  // check if UPPMAX project number is specified
  return !(workflow.profile == 'slurm' && !params.project)
}

def defReferencesFiles(genome) {
  if (genome == "smallGRCh37") {
    return [
    '1000G_phase1.indels.b37.small.vcf.gz',
    '1000G_phase3_20130502_SNP_maf0.3.small.loci',
    'b37_cosmic_v74.noCHR.sort.4.1.small.vcf.gz',
    'dbsnp_138.b37.small.vcf.gz',
    'human_g1k_v37_decoy.small.fasta.gz',
    'Mills_and_1000G_gold_standard.indels.b37.small.vcf.gz',
    'small.intervals'
    ]
  } else if (genome == "GRCh37") {
    return   [
    '1000G_phase1.indels.b37.vcf.gz',
    '1000G_phase3_20130502_SNP_maf0.3.loci.tar.bz2',
    'GRCh37_Cosmic_v83.vcf.tar.bz2',
    'dbsnp_138.b37.vcf.gz',
    'human_g1k_v37_decoy.fasta.gz',
    'Mills_and_1000G_gold_standard.indels.b37.vcf.gz',
    'wgs_calling_regions.grch37.list'
    ]
  } else exit 1, "Can't build this reference genome"
}

def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def helpMessage() {
  // Display help message
  this.sarekMessage()
  log.info "    Usage:"
  log.info "       nextflow run buildReferences.nf --refDir <pathToRefDir> --genome <genome>"
  log.info "    --refDir <Directoy>"
  log.info "       Specify a directory containing reference files."
  log.info "    --outDir <Directoy>"
  log.info "       Specify an output directory"
  log.info "    --genome <Genome>"
  log.info "       Choose which genome to build references from"
  log.info "       Possible values are:"
  log.info "         GRCh37"
  log.info "         smallGRCh37"
  log.info "    --help"
  log.info "       you're reading it"
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line: " + workflow.commandLine
  log.info "Project Dir : " + workflow.projectDir
  log.info "Launch Dir  : " + workflow.launchDir
  log.info "Work Dir    : " + workflow.workDir
  log.info "Out Dir     : " + params.outDir
  log.info "Genome      : " + params.genome
  log.info "Containers"
  if (params.repository != "") log.info "  Repository   : " + params.repository
  if (params.containerPath != "") log.info "  ContainerPath: " + params.containerPath
  log.info "  Tag          : " + params.tag
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def sarekMessage() {
  // Display Sarek message
  log.info "Sarek - Workflow For Somatic And Germline Variations ~ ${workflow.manifest.version} - " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def startMessage() {
  // Display start message
  SarekUtils.sarek_ascii()
  this.sarekMessage()
  this.minimalInformationMessage()
}

workflow.onComplete {
  // Display complete message
  this.nextflowMessage()
  this.sarekMessage()
  this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

workflow.onError {
  // Display error message
  this.nextflowMessage()
  this.sarekMessage()
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}
