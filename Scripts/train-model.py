"""Train the per-tap location classifier on events_swift.csv from one or more sessions
and export it for TapCore.TapClassifier.

  python3 Scripts/train-model.py --out model/tapmodel.json experiments/data/<session> [...]
"""
import argparse, csv, json, numpy as np, warnings
warnings.filterwarnings('ignore')
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import GroupKFold
from sklearn.metrics import balanced_accuracy_score, confusion_matrix

ap = argparse.ArgumentParser()
ap.add_argument('sessions', nargs='+'); ap.add_argument('--out', default='model/tapmodel.json')
ap.add_argument('--model', choices=['forest', 'logistic'], default='forest')
ap.add_argument('--with-other', action='store_true', help='add a reject class from bump/trackpad/move taps')
args = ap.parse_args()

def location(f):
    if f.startswith('mac_left'): return 'mac_left'
    if f.startswith('mac_right'): return 'mac_right'
    if f.startswith('desk'): return 'desk'
    if f.split('_')[0] in ('bump', 'trackpad', 'move', 'palm'): return 'other' if args.with_other else None
    return None  # idle/typing (typing is gated by key_age at runtime), gesture-protocol files

rows, feats = [], None
for si, s in enumerate(args.sessions):
    with open(f'{s}/events_swift.csv') as fh:
        rd = csv.DictReader(fh); feats = rd.fieldnames[5:]
        for r in rd:
            if r['in_motion'] == 'True' or location(r['file']) is None: continue
            r['session'] = si; rows.append(r)
CLASSES = ['mac_left', 'mac_right', 'desk'] + (['other'] if args.with_other else [])
X = np.array([[float(r[f]) for f in feats] for r in rows])
y = np.array([location(r['file']) for r in rows])
t = np.array([float(r['t']) for r in rows])
files = np.array([f"{r['session']}/{r['file']}" for r in rows])
# group = session × which fifth of its recording -> holds out contiguous time blocks
dur = {f: t[files == f].max() for f in set(files)}
groups = np.array([f'{r["session"]}:{min(4, int(5 * ti / (dur[f] + 1e-9)))}' for r, ti, f in zip(rows, t, files)])
print('taps per class:', {c: int((y == c).sum()) for c in CLASSES})

def make(kind):
    if kind == 'forest':
        return RandomForestClassifier(200, max_depth=10, min_samples_leaf=2, class_weight='balanced', random_state=0)
    return LogisticRegression(max_iter=3000, class_weight='balanced')

def cv_proba(kind):
    P = np.zeros((len(y), len(CLASSES)))
    for tr, te in GroupKFold(5).split(X, y, groups):
        m = make(kind)
        if kind == 'logistic':
            sc = StandardScaler().fit(X[tr]); m.fit(sc.transform(X[tr]), y[tr]); p = m.predict_proba(sc.transform(X[te]))
        else:
            m.fit(X[tr], y[tr]); p = m.predict_proba(X[te])
        P[np.ix_(te, [CLASSES.index(c) for c in m.classes_])] = p
    return P

for kind in ('logistic', 'forest'):
    P = cv_proba(kind); pred = np.array(CLASSES)[P.argmax(1)]
    print(f'\n== {kind}: per-tap balanced acc {balanced_accuracy_score(y, pred):.1%}')
    cm = confusion_matrix(y, pred, labels=CLASSES)
    print('   rows=true ' + ''.join(f'{c:>10s}' for c in CLASSES))
    for c, r in zip(CLASSES, cm): print(f'   {c:>9s} ' + ''.join(f'{v:10d}' for v in r))
    # simulated gestures: average probabilities of k consecutive taps from the same recording
    for k in (2, 3):
        hit = tot = 0
        for c in CLASSES[:3]:
            for f in set(files[y == c]):
                idx = np.where((files == f) & (y == c))[0]; idx = idx[np.argsort(t[idx])]
                for j in range(0, len(idx) - k + 1, k):
                    pm = P[idx[j:j + k]].mean(0); tot += 1; hit += CLASSES[pm.argmax()] == c
        print(f'   simulated {k}-tap gesture location accuracy: {hit}/{tot} = {hit / tot:.1%}')

# export the final model trained on everything
m = make(args.model)
if args.model == 'logistic':
    sc = StandardScaler().fit(X); m.fit(sc.transform(X), y)
    order = [list(m.classes_).index(c) for c in CLASSES]
    out = dict(type='logistic', classes=CLASSES, features=feats, mean=sc.mean_.tolist(), scale=sc.scale_.tolist(),
               coef=m.coef_[order].tolist(), intercept=m.intercept_[order].tolist())
else:
    m.fit(X, y)
    order = [list(m.classes_).index(c) for c in CLASSES]
    trees = []
    for est in m.estimators_:
        tr = est.tree_
        v = tr.value[:, 0, :][:, order]; v = v / v.sum(1, keepdims=True)
        trees.append(dict(left=tr.children_left.tolist(), right=tr.children_right.tolist(), feature=tr.feature.tolist(),
                          threshold=[round(x, 6) for x in tr.threshold.tolist()], value=np.round(v, 4).tolist()))
    out = dict(type='forest', classes=CLASSES, features=feats, trees=trees)
json.dump(out, open(args.out, 'w'), separators=(',', ':'))
print(f'\nexported {args.model} -> {args.out}')
