import os
import sys
from contextlib import closing

import numpy as np
import pandas as pd
import shogun as sg


def read_data(filename, window):
    # center - lwin = start of the window (inclusively)
    # center + rwin + 2 = end of the window (exclusively)
    center = 150
    lwin = window[0]
    rwin = window[1]

    data = pd.read_csv(filename, sep=';')
    data = data.dropna(axis=0, how='any', inplace=False)
    data.sequence = data.sequence.str[center - lwin: center + rwin + 2]

    return data


def read_model(filename):
    svm = sg.LibSVM()

    model_file = sg.SerializableHdf5File(filename, "r")

    with closing(model_file):
        if not svm.load_serializable(model_file):
            exit(1)

    return svm


def parser():
    from argparse import ArgumentParser
    p = ArgumentParser(description="Classify splice sites")
    p.add_argument('data_filename', metavar='INPUT', type=str,
                   help='filename of the input')
    p.add_argument('model_filename', metavar='MODEL', type=str,
                   help='filename of the model')
    p.add_argument('window_inner', type=int)
    p.add_argument('window_outer', type=int)
    p.add_argument('site', type=str, help='donor or acceptor')
    p.add_argument('output_folder', type=str)
    p.add_argument('-c', '--cpus', type=int, default=1,
                   dest='ncpus',
                   help='number of CPUs')
    return p


if __name__ == "__main__":
    argparser = parser().parse_args()

    sg.Parallel().set_num_threads(argparser.ncpus)

    win_in = argparser.window_inner
    win_out = argparser.window_outer
    window = (win_out, win_in) if argparser.site == 'donor' else (win_in, win_out)

    data = read_data(argparser.data_filename, window=window)
    features = sg.StringCharFeatures(data.sequence.tolist(), sg.RAWBYTE)
    labels = sg.BinaryLabels(np.array(data.label))
    model = read_model(argparser.model_filename)

    predict = model.apply_binary(features)

    acc = sg.AccuracyMeasure()

    model_name = os.path.split(argparser.model_filename)[0].split('/')[-1]
    with open(f'{argparser.output_folder}/{argparser.data_filename}-{model_name}-results.txt', 'w') as f:
        f.writelines(
            ["Accuracy: {}".format(acc.evaluate(predict, labels)),
             " -TP: {}".format(acc.get_TP()),
             " -FP: {}".format(acc.get_FP()),
             " -TN: {}".format(acc.get_TN()),
             " -FN: {}".format(acc.get_FN()),
             ])

    data.assign(pred=pd.Series(list(predict.get_int_labels()))) \
        .to_csv(sys.stdout, sep=';', index=False)
