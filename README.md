Overview
==========
We present a pipeline for removing fungal introns from meta-genome assemblies. The output is the original assembly
purged of potential intron sequences. 

The pipeline is separated into 3 stages, each represented by a bash script.

Breaking down the steps into separate stages is necessary due to asynchronous and distributed nature of assembly processing.
The stages are following:
1) *Split the assembly into smaller shards*
   * The size of the shards should be less than 70Mb for reasonable processing times
2) *Process the shards (in parallel)*
   * Here typically the shards are submitted as a job for execution on some cluster
3) *Combine the results*
    * Once the partial results are complete, merge them into a single cleaned assembly

### Project folders    
The asynchronous and distributed nature of the task requires a central location where partial results are stored.
We therefore introduce a concept of a *project folder*.

At the beginning, the folder only contains the assembly fasta to process. As the pipeline progresses, the folder gets
populated by partial results and helper files. 
We will now take a look at the structure of the folder at each stage of the pipeline (using a test assembly *ctg_k141_2751450.fa* ). 

The starting appearance is simply:

```
.
└── ctg_k141_2751450.fa
```

1. After the first step (**assembly sharding**). :
```
.
├── assembly_shards/
│   ├── ctg_k141_2751450_0.fa
│   ├── ctg_k141_2751450_1.fa
│   └── ...
├── ctg_k141_2751450_no_duplicates.fa
└── ctg_k141_2751450.fa
```
The `assembly_shards` directory simply contains the shards themselves. The file suffix signals the index of the sequence first present in the shard
Note that the sharding process implicitly removes duplicated records from the assembly. 
The pipeline will later work only with the non-duplicated sequences.

2. After the second step (**independent intron removal from each shard**). For simplicity, we only chose to process the
negative strand (the `minus` suffix of files)
```
.
├── assembly_shards/
├── results/
│   ├── ctg_k141_2751450_0.fa_results_minus/
│   ├── ctg_k141_2751450_1.fa_results_minus/
├── scratchdir/
├── assembly_shards.txt
├── ctg_k141_2751450_no_duplicates.fa
└── ctg_k141_2751450.fa
```
Here a few new items appear. The most important is the `results` directory with partial results for each shard.
`scratchdir` contains only temporary processing files and is of no importance apart from debugging. 
`assebmly_shards.txt` holds the list of shard names to process. In the basic scenario all shards are present; 
In specific cases, where the user needs only a subset of shards processed (e.g. when some cluster node crashes), 
he or she can modify this file to specify the subset required.

3. After the final step (**combining partial results**).
```
.
├── assembly_shards/
├── results/
├── scratchdir/
├── assembly_shards.txt
├── ctg_k141_2751450_no_duplicates.fa
├── ctg_k141_2751450.fa
├── cut-coords-minus-strand-full.csv
└── pruned_ctg_k141_2751450_minus.fa
```
Two new files appear - the pruned assembly (with non-duplicated sequences), and the CSV with cut coordinates.
Both files are assembled from the partial results inside the `results` folder.

Quickstart
==========
Within the `./pipeline` folder, run:

1) **Split the assembly into smaller shards for parallel/distributed processing:**

`bash shard_assembly.sh -p project_path -n seqs_per_shard`

2) **Process the shards:**

`bash batch_pipeline.sh -m models_settings -p project_path -s strand`

3) **Combine the results**

`bash combine_results.sh -p project_path`


As a demonstration, we will process a test contig ctg_k141_2751450. The contig is part of the sources and is located
in the test directory *test/projects/project_ctg_k141_2751450*.

First, split the assembly into shards with 1 sequence each. The shards will be saved into the project directory
under the folder `assembly_shards`

`bash shard_assembly.sh -p /home/john/mycointrons/test/projects/project_ctg_k141_2751450/ -n 1`

Next, we process the shards, removing introns from both strands. We will use the neural nets models as indicated by 
the `nn100` argument. The computations will be performed locally:

`bash batch_pipeline.sh -m nn100 -p /home/john/mycointrons/test/projects/project_ctg_k141_2751450 -s both`

Finally, we combine the partial results into a single assembly purged from introns. As we were processing both strands, 
the call results in two separate fastas one for each strand (named `pruned_ctg_k141_2751450_no_duplicates_minus.fa` and `pruned_ctg_k141_2751450_no_duplicates_plus.fa`)

`bash combine_results.sh -p /home/john/mycointrons/test/projects/project_ctg_k141_2751450`

USAGE
=====

for model setting, use one of the following
    * 'svmb' (standing for SVM models trained on Basidiomycota; very slow)
    * 'nn100' (standing for neural net with 0-100 windows; faster)
    * 'nn200' (standing for neural net with 200-200 windows; slower, more accurate)

The process of intron removal is roughly:
    1) Find all donor dimers and perform splice site classification
    2) Find all acceptor dimers, remove orphan candidates (AG with no GT in acceptable range) and perform splice site classification
    3) Pair positively classified splice site candidates to form an intron candidate dataset
    4) Classify the intron dataset (only for SVM models)
    5) Cut positively classified introns. Overlaps are resolved with length prior distribution cut-off

INSTALLATION
============

(1) PYTHON libraries
      All the scripts assume Python3 is used.

      We need two separate environments with similar libraries, since Shogun and Keras don't work together in one env.

        conda create -n mykointron_shogun python=3.6
        conda config --env --add channels conda-forge anaconda
        conda activate mykointron_shogun
        conda install pandas
        conda install -c anaconda biopython
        conda install docopt
        conda install scikit-learn
        (pip install gffutils)
        conda install -c conda-forge shogun

        conda create -n mykointron python=3.6
        conda activate mykointron
        conda install pandas
        conda install -c anaconda biopython
        conda install docopt
        conda install scikit-learn
        conda install -c anaconda keras

        pip3 install --upgrade tensorflow

(2) If this project is downloaded via Git, ask for models at lequyanh@fel.cvut.cz as they are too large for GitHub
    Save them to ./pipeline/bestmodels/basidiomycota
        Applies only for SVM models, NN models are included and don't need extra download