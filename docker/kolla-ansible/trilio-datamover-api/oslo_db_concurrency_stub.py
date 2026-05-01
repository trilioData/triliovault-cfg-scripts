"""
Compatibility stub for oslo_db.concurrency.

oslo_db.concurrency (containing the Semaphores class) was part of the
oslo-incubator era and was removed from oslo.db in modern releases.
python3-dmapi-el9 still imports it via dmapi.db.api. This stub provides
the same interface so the import succeeds against current oslo.db.
"""
import threading


class Semaphores(object):

    def __init__(self):
        self._lock = threading.Lock()
        self._semaphores = {}

    def get(self, name):
        with self._lock:
            return self._semaphores.setdefault(name, threading.Semaphore())

    def __len__(self):
        return len(self._semaphores)

    def __contains__(self, name):
        return name in self._semaphores
