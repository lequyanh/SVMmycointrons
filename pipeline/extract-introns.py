import logging
import sys
from collections import defaultdict

from Bio import SeqIO

logging.basicConfig(
    level=logging.INFO,
    filename='extract-introns.log',
    filemode='w'
)

def sequences(file):
    for line in file.readlines():
        words = line.strip().split(' ')
        assert len(words) >= 3, \
            'each line must contain at least scaffold with a start and stop position'
        assert len(words) % 2 == 1, \
            'each line must contain a scaffold and pairs of start/end positions'
        yield words[0], [int(p) for p in words[1:]]


if __name__ == '__main__':
    #  name of the FASTA assembly file
    fasta_filename = sys.argv[1]
    # name of the file containing the sequences
    sequences_filename = sys.argv[2]

    # scaffold start end start end start end

    scaffold_sequences = defaultdict(list)

    # load all sequences (a sequence is identified by the scaffold and start/end position pairs)
    with open(sequences_filename, 'r') as sequences_file:
        for scaffold, positions in sequences(sequences_file):
            scaffold_sequences[scaffold].append(positions)

    extracto_set = dict()
    print('scaffold;start;end;sequence')
    with open(fasta_filename, 'r') as fasta_file:
        for scaffold in SeqIO.parse(fasta_file, 'fasta'):
            to_extract = scaffold_sequences[scaffold.id]
            logging.info(f'Extracting from scaffold {to_extract}')
            for positions in to_extract:
                scaffold_seq = str(scaffold.seq)
                extracted = ''.join(scaffold_seq[positions[i] - 1:positions[i + 1]]
                                    for i in range(0, len(positions), 2))

                existing = extracto_set.get(extracted, None)
                if existing:
                    logging.info(f'{existing} MATCHES {scaffold.id} -- {positions} -- {extracted}')
                else:
                    extracto_set[extracted] = f'{scaffold.id} -- {positions}'

                print(scaffold.id, *positions, extracted, sep=';')
