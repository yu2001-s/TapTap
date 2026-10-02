# Collecting data and training a model

The app includes a 200-tree random forest with 28 sensor features. Training is optional; the shipped app uses `model/tapmodel.json` without a Python runtime.

## Collect

From the repository root on a supported MacBook:

```sh
swift run taptap collect --protocol taps --surface desk
swift run taptap collect --protocol gestures --surface desk
```

The interactive CLI guides you through positive taps and negative examples such as typing, movement, and placing your hands on the palm rest. It saves each session to `experiments/data/<timestamp>/`, which is ignored by Git.

CSV recordings contain accelerometer, gyroscope, and time-since-input measurements. Session metadata includes the Mac hardware model, surface description, and any note you supply. Review data before sharing it; the collection tool does not upload it.

## Extract, train, and evaluate

```sh
swift run taptap extract experiments/data/<tap-session>
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r Scripts/requirements-training.txt
python3 Scripts/train-model.py --with-other --out model/tapmodel.json \
  experiments/data/<tap-session>
swift run taptap eval experiments/data/<gesture-session> --verbose
```

Use several representative sessions and surfaces when possible. The trainer holds out grouped time blocks during cross-validation, then exports the final model. Keep whole-gesture recordings separate to evaluate recognition, not just individual tap classification.

The bundled model's classes are `mac_left`, `mac_right`, `desk`, and `other`. Only Mac palm-rest double/triple taps are mapped to app actions. The runtime adds movement/input gates and strength thresholds; per-tap classification accuracy alone does not describe the full user experience.

Raw training sessions are not included in the public repository. Reproducing new weights requires your own recordings.
