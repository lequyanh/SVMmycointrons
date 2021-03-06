#!/bin/bash

# Pipeline settings:
#  - splice site dimers
DONOR="GT"
ACCEPTOR="AG"
# - size of windows around candidate splice site to extract
WINDOW_DIAMETER=200
#  - range of intron lengths
#    considered when extracting introns from the positions of the positively classified splice sites
INTRON_MIN_LENGTH=40
INTRON_MAX_LENGTH=100
#  - order of the spectrum kernel
#    it is used in the intron prediction and it must be equal to the order used while training
SPECT_KERNEL_ORDER=6
#  - files with intron lengths to build a probability distribution over intron lengths
#    used as the cutting step to decide which candidate to cut in case of overlap
intron_lens_data="basidiomycota-intron-lens.txt"

# OUTPUT FILES
#  - names of the splice site datasets
#    it will be created before the splice sites classification
DONOR_FILE="splice-site-donor-dataset.csv"
ACCEPTOR_FILE="splice-site-acceptor-dataset.csv"
#  - names of the files for splice site classification results
DONOR_RESULT="splice-site-donor-result.csv"
ACCEPTOR_RESULT="splice-site-acceptor-result.csv"
#  - name of the file that contains positions of alleged introns
#    it will be created after the splice sites classification
INTRON_POSITIONS_FILE="intron-positions-dataset.csv"
#  - name of the file that contains extracted intron sequences
INTRON_FILE="intron-dataset.csv"
#  - name of the file for intron classification results
INTRON_RESULT="intron-result.csv"
CUT_COORDS_FILE="cut-coords.csv"

## Pipeline inputs:
#  - Assembly file (FASTA)
assembly_filepath=$1 # ~/Desktop/mykointrons-data/data/Assembly/Kocim1_AssemblyScaffolds.fasta
#  - donor splice site prediction model
splice_site_donor_model=$2
#  - acceptor splice site prediction model
splice_site_acceptor_model=$3
#  - intron prediction model
intron_model=$4
# settings for work with sequence windows
window_inner=$5
window_outer=$6
# strand
strand=$7
# working directory (the .py scripts must be present)
working_dir=$8
# results directory (where to put result files)
results_dir=$9
# number of CPUs
number_cpus=${10}
#  - in case of validation
intron_source=${11}

if [ -z "$number_cpus" ]; then
    number_cpus=12
fi
NUMBER_CPUS=${number_cpus}
echo "Using ${NUMBER_CPUS} CPU cores..."

#  - window size used when extracting splice sites sequences
#    the size is equal to the size of window used to train the models
DONOR_LWINDOW=${window_outer}
DONOR_RWINDOW=${window_inner}
ACCEPTOR_LWINDOW=${window_inner}
ACCEPTOR_RWINDOW=${window_outer}

## Derived variables:
# regex used to determine splice site sequences
donor_regex=";[ACGT]{$WINDOW_DIAMETER}$DONOR[ACGT]{$WINDOW_DIAMETER}$"
acceptor_regex=";[ACGT]{$WINDOW_DIAMETER}$ACCEPTOR[ACGT]{$WINDOW_DIAMETER}$"
# regex to filter positively classified splice sites
positive_splice_sites=";1$"
# regex to filter positively classified introns
positive_introns=";1$"

## Setting up the correct conda environment
eval "$(command conda 'shell.bash' 'hook' 2> /dev/null)"
conda activate mykointron_shogun

PYTHON=$(which python)
# -------------------------------------------------------------

# The process (roughly):
#  1. Find all donors (GT) and use them to create a donor dataset.
#  2. Find all acceptors (AG) and use them to create an acceptor dataset.
#  3. Run two classification tasks in parallel:
#     a) classify donors (given the donor dataset),
#     b) classify acceptors (given the acceptor dataset).
#  4. Wait until both the classification tasks finish. Then find all possible pairs GT-AG given
#     positively classified donors and acceptors, and use them to create an intron dataset.
#  5. Run a classification task to identify introns.
# -------------------------------------------------------------

# exit after any error
set -e
# enable pipe fail
set -o pipefail
cd "$working_dir" || exit

function extract_donor_acceptor_step() {
  echo "Extracting donors and acceptors from [$assembly_filepath] on $strand strand..."

  # prepare files for the donor and acceptor datasets
  echo "scaffold;position;sequence" >$DONOR_FILE
  echo "scaffold;position;sequence" >$ACCEPTOR_FILE

  $PYTHON extract-donor-acceptor.py "${assembly_filepath}" \
    $DONOR $ACCEPTOR \
    $WINDOW_DIAMETER $WINDOW_DIAMETER \
    $WINDOW_DIAMETER $WINDOW_DIAMETER \
    $strand |
    gawk -v donor="${donor_regex}" \
      -v acceptor="${acceptor_regex}" \
      -v donor_file=$DONOR_FILE \
      -v acceptor_file=$ACCEPTOR_FILE \
      '$0 ~ donor {print >> donor_file} $0 ~ acceptor {print >> acceptor_file}'

  echo "Donors extracted to [$DONOR_FILE]."
  echo "Acceptors extracted to [$ACCEPTOR_FILE]."
  echo ""
}

function classify_splice_sites_step() {
  # prepare files for the donor and acceptor classification results
  echo "scaffold;position" >$DONOR_RESULT
  echo "scaffold;position" >$ACCEPTOR_RESULT

  # classify the donors and acceptors, keep only the positively classified samples
  # keep only the columns `scaffold`, and `position` (1st and 2nd)
  echo "Classifying with SVM models"
  echo "Starting classification of splice sites with $NUMBER_CPUS CPUs..."

  date

  $PYTHON classify-splice-sites.py $DONOR_FILE "$splice_site_donor_model" \
    "${DONOR_RWINDOW}" "${DONOR_LWINDOW}" \
    "donor" -c $NUMBER_CPUS |
    grep $positive_splice_sites |
    cut -d ';' -f -2 >>$DONOR_RESULT

  $PYTHON filter-orphan-acceptors.py $ACCEPTOR_FILE $DONOR_RESULT $INTRON_MIN_LENGTH $INTRON_MAX_LENGTH

  $PYTHON classify-splice-sites.py $ACCEPTOR_FILE "$splice_site_acceptor_model" \
    "${ACCEPTOR_LWINDOW}" "${ACCEPTOR_RWINDOW}" \
    "acceptor" -c $NUMBER_CPUS |
    grep $positive_splice_sites |
    cut -d ';' -f -2 >>$ACCEPTOR_RESULT

  date
  echo "Positively classified donors are in [$DONOR_RESULT]."
  echo "Positively classified acceptors are in [$ACCEPTOR_RESULT]."
  echo ""
}

function pair_splice_sites_and_extract_introns_step() {
  echo "Getting intron positions..."

  # given the splice sites classification, output positions of possible introns
  $PYTHON generate-pairs.py $DONOR_RESULT $ACCEPTOR_RESULT \
    $INTRON_MIN_LENGTH $INTRON_MAX_LENGTH >$INTRON_POSITIONS_FILE

  echo "Intron positions are in [$INTRON_POSITIONS_FILE]."
  echo "Extracting introns from the positions..."

  # extract introns from the positions from the previous step
  $PYTHON extract-introns.py "$assembly_filepath" $INTRON_POSITIONS_FILE "$strand" >$INTRON_FILE

  echo "Intron sequences are extracted in [$INTRON_FILE]."
  echo ""
}

function classify_introns_step() {
  echo "Starting classification of the introns using spectral kernel order ${SPECT_KERNEL_ORDER}"
  CLASSIFICATION_RESULTS='classified-introns-dataset.csv'

  # classify the introns
  # keep only the positively classified samples
  # keep only the columns `scaffold`, `start`, and `end` (1st, 2nd, and 3rd)
  if [ "${splice_site_donor_model: -3}" == ".h5" ]; then
    echo "Using NN models - skipping intron classification"
    $PYTHON classify-introns-stub.py $INTRON_FILE >$CLASSIFICATION_RESULTS
  else
    $PYTHON classify-introns.py -c $NUMBER_CPUS $INTRON_FILE "$intron_model" $SPECT_KERNEL_ORDER >$CLASSIFICATION_RESULTS
  fi

  echo "scaffold;start;end" >$INTRON_RESULT
  echo "Detected introns are in [$INTRON_RESULT]."

  if grep -q $positive_introns < $CLASSIFICATION_RESULTS
  then
    cat $CLASSIFICATION_RESULTS | grep $positive_introns | cut -d ';' -f -3  >> $INTRON_RESULT
  else
    echo "No positive introns found. $INTRON_RESULT created anyway for consistency"
  fi
}

function validate_introns_step() {
  echo "Labeling intron dataset"
  $PYTHON label_introns.py "$INTRON_FILE" "$intron_source" $INTRON_MIN_LENGTH $INTRON_MAX_LENGTH "$strand"

  if [ "${splice_site_donor_model: -3}" == ".h5" ]; then
    echo "Using NN models - skipping intron classification. Validating candidates right away"
    $PYTHON classify-introns-stub.py $INTRON_FILE >$INTRON_RESULT
  else
    echo "Starting validation of the intron dataset using spectral kernel order ${SPECT_KERNEL_ORDER}"
    $PYTHON_SHOGUN classify-introns.py -c $NUMBER_CPUS $INTRON_FILE "$intron_model" $SPECT_KERNEL_ORDER |
      cut --complement -d ';' -f4 >>$INTRON_RESULT
  fi
}

function cut_introns_step() {
  echo "Cutting introns. Intron length distribution derived from file ${intron_lens_data}"

  echo "scaffold;start;end" >${CUT_COORDS_FILE}
  $PYTHON prune_probabilistic.py "${assembly_filepath}" ${INTRON_RESULT} "${strand}" ${intron_lens_data} >>"${CUT_COORDS_FILE}"
}

function cleanup(){
  rm ./*dataset.csv
  rm ./*.py
  rm ./*.txt
  rm -rf ./__pycache__/
  rm ./*.log
}

extract_donor_acceptor_step
classify_splice_sites_step
pair_splice_sites_and_extract_introns_step

if [ "$intron_source" ]; then
  validate_introns_step
else
  classify_introns_step
fi

cut_introns_step

echo "Pipeline log for file ${assembly_filepath}" >pipeline.txt
for p in ./*.log; do
  {
    echo "================================== ${p} =========================================="
    cat "$p"
  } >>pipeline.txt
done

cleanup

mkdir -p "$results_dir"
mv ./* "$results_dir"
printf "Results are saved into %s. \n\n" "$results_dir"
