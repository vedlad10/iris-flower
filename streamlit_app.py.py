from sklearn.preprocessing import StandardScaler
from sklearn.svm import LinearSVC
import streamlit as st
from sklearn import datasets
import numpy as np
from sklearn.pipeline import Pipeline
iris = datasets.load_iris()
X = iris["data"][:, (2, 3)] # petal length, petal width
y = (iris["target"])
svm_clf = Pipeline([
("scaler", StandardScaler()),
("linear_svc", LinearSVC(C=1, loss="hinge")),
])
svm_clf.fit(X, y)
st.title("Iris Flower Classifier 🌸")
petal_length = st.slider("Petal Length (cm)", 0.1, 7.0, 5.0)
petal_width = st.slider("Petal Width (cm)", 0.1, 3.0, 1.5)
if st.button("Predict"):
    sample = np.array([[petal_length, petal_width]])
    prediction = svm_clf.predict(sample)[0]
    st.write(f"Predicted Species: **{iris.target_names[prediction]}**")


import joblib

joblib.dump(svm_clf, "svm_iris_model.pkl")
