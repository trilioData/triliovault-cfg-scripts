# Copyright 2015 TrilioData Inc.
# All Rights Reserved.

import os
import time
from datetime import datetime
from datetime import timedelta
from workloadmgr.openstack.common import timeutils
from workloadmgr.openstack.common import fileutils
from oslo_config import cfg
from keystoneclient.v2_0 import client as keystone_v2
from NamedAtomicLock import NamedAtomicLock
from workloadmgr.openstack.common import log as logging
from workloadmgr.vault import vault
import base64
from urllib.parse import urlparse

auditlog_opts = [
    cfg.StrOpt('auditlog_admin_user',
               default='admin',
               help='auditlog admin user'),
    cfg.StrOpt('keystone_endpoint_url',
               default='http://localhost:35357/v2.0',
               help='keystone endpoint url for connecting to keystone'),
    cfg.StrOpt('audit_log_file',
               default='auditlog.log',
               help='file name to store all audit log entries'),
    cfg.StrOpt('legacy_audit_log_file',
               default='/var/triliovault/auditlogs/auditlog.log',
               help='Legacy audit log file path to store all audit log entries'),
]

LOG = logging.getLogger(__name__)
CONF = cfg.CONF
CONF.register_opts(auditlog_opts)

_auditloggers = {}
lock = NamedAtomicLock('auditlog_lock', maxLockAge=15)

def getAuditLogger(name='auditlog', version='unknown',
                   filepath=None, CONF1=None):
    if CONF1 is not None:
        for backup_endpoint in CONF1.vault_storage_filesystem_export.split(','):
            base64encode = base64.b64encode(urlparse('//' + backup_endpoint).path)
            mountpath = os.path.join(CONF.vault_data_directory,
                                     base64encode)
            filepath = os.path.join(mountpath, CONF1.cloud_unique_id)
            filepath = os.path.join(filepath, CONF.audit_log_file)
            break
    if filepath is None:
        try:
            (backup_target, path) = vault.get_settings_backup_target()
            filepath = os.path.join(backup_target.mount_path, CONF.cloud_unique_id)
            filepath = os.path.join(filepath, CONF.audit_log_file)
        except:
            filepath = "/tmp/"
            filepath = os.path.join(filepath, CONF.audit_log_file)
    if name not in _auditloggers:
        _auditloggers[name] = AuditLog(name, version, filepath)

    return _auditloggers[name]


class AuditLog(object):
    def __init__(self, name, version, filepath, *args, **kwargs):
        self._name = name
        self._version = version
        self._filepath = filepath
        head, tail = os.path.split(filepath)
        fileutils.ensure_tree(head)

    def log(self, context, message, object=None, *args, **kwargs):
        try:
            if not os.path.exists(os.path.dirname(lock.lockPath)):
                os.mkdir(os.path.dirname(lock.lockPath))
            lock.acquire()

            if message is None:
                message = 'NA'
            if object is None:
                object = {}

            auditlogmsg = timeutils.utcnow().strftime("%d-%m-%Y %H:%M:%S.%f")
            user = getattr(context, "user", context.user_id) or context.user_id
            tenant = getattr(
                context,
                "tenant",
                context.project_id) or context.project_id
            auditlogmsg = auditlogmsg + ',' + user + ',' + context.user_id
            display_name = object.get('display_name', 'NA')
            if not display_name:
                display_name = object.get('id', 'NA')
            auditlogmsg = auditlogmsg + ',' + \
                display_name + ',' + object.get('id', 'NA')
            auditlogmsg = auditlogmsg + ',' + message
            auditlogmsg = auditlogmsg + ',' + tenant + ',' + context.project_id + '\n'

            head, tail = os.path.split(self._filepath)
            fileutils.ensure_tree(head)
            with open(self._filepath, 'a') as auditlogfile:
                auditlogfile.write(auditlogmsg, *args, **kwargs)
        except Exception as ex:
            LOG.exception(ex)
        finally:
            lock.release()

    def get_records(self, time_in_minutes, time_from, time_to):

        def _get_records_from_audit_file(filename=None):
            records = []

            filename = filename or self._filepath

            head, tail = os.path.split(filename)
            fileutils.ensure_tree(head)

            if not os.path.exists(filename):
                return records

            def _next_record():
                now = timeutils.utcnow()
                with open(filename) as auditlogfile:
                    for line in auditlogfile:
                        try:
                            line = line.strip('\x00')
                            values = line.split(",")
                            record_time = datetime.strptime(
                                values[0], "%d-%m-%Y %H:%M:%S.%f")
                            local_time = datetime.strftime(
                                record_time, "%I:%M:%S.%f %p - %m/%d/%Y")
                            fetch = False
                            if time_in_minutes:
                                if (now -
                                        record_time) < timedelta(minutes=time_in_minutes):
                                    fetch = True
                            else:
                                if record_time >= time_from and record_time <= time_to:
                                    fetch = True

                            if fetch is True:
                                record = {'Timestamp': local_time,
                                          'UserName': values[1],
                                          'UserId': values[2],
                                          'ObjectName': values[3],
                                          'ObjectId': values[4],
                                          'Details': values[5],
                                          'ProjectName': '',
                                          'ProjectId': '',
                                          }
                                if len(values) > 6:
                                    record['ProjectName'] = values[6]
                                    record['ProjectId'] = values[7]
                                yield record
                            else:
                                continue
                        except Exception as ex:
                            LOG.exception(ex)
                            #In case if we have any corrupted log, we should send other
                            #available logs.
                            continue

            for rec in _next_record():
                records.insert(0, rec)

            return records

        records = _get_records_from_audit_file()
        # for backward compatilibity
        if os.path.exists(CONF.legacy_audit_log_file):
            records += _get_records_from_audit_file(CONF.legacy_audit_log_file)
        return records