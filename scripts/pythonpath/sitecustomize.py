"""Import cv2 before coverage.py starts tracing.

Python imports sitecustomize at interpreter startup, before pytest loads any
plugin, so this runs earlier than pytest-cov can enable the tracer.

Why it is needed: cv2/__init__.py bootstraps by popping "cv2" out of
sys.modules, importing the native extension, then merging its symbols back
into the Python-level module. With coverage's tracer already active that merge
does not complete, so cv2.dnn is still bare when cv2/typing/__init__.py reads
cv2.dnn.DictValue, and the import dies with:

    AttributeError: module 'cv2.dnn' has no attribute 'DictValue'

Reproducible without pytest -- coverage.Coverage().start() followed by
import cv2 is enough. Importing cv2 first sets sys.OpenCV_LOADER, so the
bootstrap in the traced process short-circuits (cv2/__init__.py:74) and never
re-runs the fragile merge.

scripts/test.sh puts this directory on PYTHONPATH.
"""

try:
    import cv2  # noqa: F401
except Exception:  # pragma: no cover
    # Never block interpreter startup. If cv2 is genuinely broken the tests
    # will say so far more clearly than a failure in here would.
    pass
