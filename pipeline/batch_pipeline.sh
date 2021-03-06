#!/bin/bash

# SYNOPSIS
#     bash batch_pipeline.sh -m models_settings -p project_path -s strand [-l #custom_batches_list] [-n number_cpus]
#
# OPTIONS
#     -m    model settings (svmb/random)
#     -p    project path with the fasta to clean sharded into fragments (stored in ./assembly_batches)
#     -s    specify strand reading direction (plus/minus/both)
#     -l    text file with the list specific assembly batches to process (e.g. to process a subset of batches)
#     -n    number of CPUs
# EXAMPLES
#     bash batch_pipeline.sh -m svmb -p /home/johndoe/Desktop/project/ -s plus
#
#     Specifying only a subset of assembly batches to process
#     bash main.sh -m svmb -p /home/johndoe/Desktop/project/ -l custom_assembly_batch_list.txt

# OBSOLETE: cutting and intron validation on fungal species):
# bash batch_pipeline.sh -m svmb -l basidiomycota.txt -d /storage/praha1/home/lequyanh/data/reduced/ -s minus

####################################################################
# FUNCTION FOR DISTRIBUTED COMPUTATION                             #
#    Please modify the function by inserting a job submission call #
#    according to standards of your cluster                        #
#                                                                  #
#    The call should execute the script 'pipeline' with given args #
#    All arguments are supplied and don't need to be modified      #
#    Their order must be however preserved                         #
####################################################################
function submit_job(){
  assembly=$1     # The path to the assembly batch
  working_dir=$2  # Isolated working directory for temporary files
  results_dir=$3  # Partial results directory for a given batch

  # >>>> !! CHANGE ME !! <<<
  # Use this call for a local execution. Or replace it with a call to submit the job to your cluster
  bash pipeline.sh "$assembly" "$dmodel" "$amodel" "$imodel" "$window_inner" "$window_outer" "$strand" "$working_dir" "$results_dir" "$ncpus"
  # >>>> !! CHANGE ME !! <<<
}
export -f submit_job

######################
# Defining constants #
######################
# Location of models and the scripts
ROOT=$(dirname "$(pwd)")
MODELS_DIR="$(pwd)/models/"

# Project sub-folders for partial and full results
BATCHES_DIR="assembly_batches"
SCRATCH_DIR="scratchdir"
RESULTS_DIR="results"

export BATCHES_DIR
export SCRATCH_DIR
export RESULTS_DIR

########################
# Processing arguments #
########################
while getopts "m:p:s:l:n:" opt; do
  case $opt in
  m)
    models_settings=$OPTARG
    echo "Settings used for classification models ${models_settings}"
    ;;
  p)
    project_path=$OPTARG
    echo "Assembly batches from the directory ${project_path} will be processed.
          Results will be saved in this directory as well."
    ;;
  l)
    fasta_list_file=$OPTARG
    echo "Names of assemblies to process will be taken from ${fasta_list_file}"
    ;;
  s)
    strand=$OPTARG
    echo "Strand ${strand}"
    ;;
  n)
    ncpus=$OPTARG
    echo "Number of CPUs ${ncpus}"
    ;;
  *)
    echo "Invalid option or argument"
    exit 1
    ;;
  esac
done

if [ -z "$fasta_list_file" ]
then
      echo "Processing all assembly batches in $project_path"

      fasta_list_file="${project_path}/assembly_batches.txt"
      ls "${project_path}/${BATCHES_DIR}" >"${fasta_list_file}"
else
      echo "Using a subset of assembly batches defined in $fasta_list_file"
fi

export strand
export project_path
export ncpus

###############################################
# PIPELINE PARAMETER SETTINGS BASED ON MODEL  #
###############################################
if [ "$models_settings" == 'svmb' ]; then
  dmodel="${MODELS_DIR}/model_donor_svmb-C10-d25-w70.hd5"
  amodel="${MODELS_DIR}/model_acceptor_svmb-C10-d25-w70.hd5"
  imodel="${MODELS_DIR}/intron_model_svmb-C7-d6.hd5"
  window_inner=70
  window_outer=70

elif [ "$models_settings" == 'random' ]; then
  dmodel="random"
  amodel="random"
  imodel="random"
  window_inner=70
  window_outer=70
fi

export amodel
export dmodel
export imodel
export window_inner
export window_outer

##########################################################
# Prepare a working directory for a given assembly batch #
# for independent processing and submits the batch       #
# for execution                                          #
##########################################################
function process_assembly_batch(){
  assembly_batch=$1

  # Prepare working and results directories for independent processing
  assembly="${project_path}/${BATCHES_DIR}/${assembly_batch}"
  working_dir="${project_path}/${SCRATCH_DIR}/${assembly_batch}_${strand}"
  results_dir="${project_path}/${RESULTS_DIR}/${assembly_batch}_results_${strand}"

  mkdir -p "$working_dir"
  ln -s -f "$ROOT/classification/classify-splice-sites.py" "${working_dir}/classify-splice-sites.py"
  ln -s -f "$ROOT/classification/classify-introns.py" "${working_dir}/classify-introns.py"
  ln -s -f "$ROOT/classification/classify-introns-stub.py" "${working_dir}/classify-introns-stub.py"
  ln -s -f "$ROOT/classification/tools.py" "${working_dir}/tools.py"

  ln -s -f "$ROOT/tools/fastalib.py" "${working_dir}/fastalib.py"
  ln -s -f "$ROOT/tools/generate-pairs.py" "${working_dir}/generate-pairs.py"
  ln -s -f "$ROOT/tools/extract-donor-acceptor.py" "${working_dir}/extract-donor-acceptor.py"
  ln -s -f "$ROOT/tools/filter-orphan-acceptors.py" "${working_dir}/filter-orphan-acceptors.py"
  ln -s -f "$ROOT/tools/extract-introns.py" "${working_dir}/extract-introns.py"

  ln -s -f "$ROOT/pruning/prune_tools.py" "${working_dir}/prune_tools.py"
  ln -s -f "$ROOT/pruning/prune_probabilistic.py" "${working_dir}/prune_probabilistic.py"

  ln -s -f "$ROOT/pipeline/basidiomycota-intron-lens.txt" "${working_dir}"

  # tell a HPC to run the pipeline script with these parameters (register a job or something similar)
  submit_job "$assembly" "$working_dir" "$results_dir"
}

function send_batches_for_execution() {
  while read assembly_batch; do
    echo "Sending for execution the assembly batch ${assembly_batch}"
    process_assembly_batch "${assembly_batch}"
  done <"$fasta_list_file"
}

#############################################
# ASSEMBLY CUTTING (FROM SHARDED FRAGMENTS) #
#############################################
export -f process_assembly_batch

if [ "$strand" == 'both' ]; then
  strand='plus'
  export strand
  send_batches_for_execution

  strand='minus'
  export strand
  send_batches_for_execution
else
  send_batches_for_execution
fi

