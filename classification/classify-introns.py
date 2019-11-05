import sys
from contextlib import closing
from pathlib import Path

import numpy as np
import pandas as pd
import shogun as sg


def read_model(filename):
    svm = sg.LibSVM()

    model_file = sg.SerializableHdf5File(filename, "r")

    with closing(model_file):
        if not svm.load_serializable(model_file):
            print("Model failed to load")
            exit(1)

    return svm


def create_features(order, dna):
    gap = 0
    reverse = False

    charfeat = sg.StringCharFeatures(sg.DNA)
    charfeat.set_features(dna)
    feats = sg.StringWordFeatures(charfeat.get_alphabet())
    feats.obtain_from_char(charfeat, order - 1, order, gap, reverse)
    preproc = sg.SortWordString()
    preproc.init(feats)
    return preproc.apply(feats)


def parser():
    from argparse import ArgumentParser
    p = ArgumentParser(description="Classify introns")
    p.add_argument('data_filename', metavar='INPUT', type=str,
                   help='filename of the input')
    p.add_argument('model_filename', metavar='MODEL', type=str,
                   help='filename of the model')
    p.add_argument('l', metavar='ORDER', type=int,
                   help='order of the spectrum kernel')
    p.add_argument('-o', '--output_folder', type=str, default='validation_results',
                   dest='output_folder',
                   help='folder where validation results are stored (see -v flag)')
    p.add_argument('-v', action='store_true', help='validation mode - calculates accuracy metrics')
    p.add_argument('-c', '--cpus', type=int, default=1,
                   dest='ncpus',
                   help='number of CPUs')
    return p


def get_result_path(model_filename, data_filename, output_folder):
    model_name = Path(model_filename).parts[-2]
    data_filename = Path(data_filename).parts[-1]
    result_path = f'{output_folder}/{data_filename}--{model_name}-results.txt'

    return result_path


if __name__ == "__main__":
    argparser = parser().parse_args()

    sg.Parallel().set_num_threads(argparser.ncpus)

    data = pd.read_csv(argparser.data_filename, sep=';')
    model = read_model(argparser.model_filename)

    features = create_features(argparser.l, data.loc[:, 'sequence'].tolist())

    predict = model.apply_binary(features)

    data.assign(pred=pd.Series(list(predict.get_int_labels()))) \
        .to_csv(sys.stdout, sep=';', index=False)

    if argparser.v:
        labels = sg.BinaryLabels(np.array(data.label))
        acc = sg.AccuracyMeasure()
        metrics = ["Accuracy: {}".format(acc.evaluate(predict, labels)),
                   " -TP: {}".format(acc.get_TP()),
                   " -FP: {}".format(acc.get_FP()),
                   " -TN: {}".format(acc.get_TN()),
                   " -FN: {}".format(acc.get_FN()),
                   ]
        metrics = '\n'.join(metrics)
        print(metrics)

        result_file_path = get_result_path(
            argparser.model_filename,
            argparser.data_filename,
            argparser.output_folder
        )
        with open(result_file_path, 'w') as f:
            f.writelines(metrics)
