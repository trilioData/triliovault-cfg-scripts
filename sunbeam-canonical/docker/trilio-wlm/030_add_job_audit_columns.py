"""Add audit columns and progress to job table.

The Job model inherits WorkloadsBase which provides created_at, updated_at,
deleted_at, deleted, version. The job table was originally created with only
jobid/status/action, and parent_jobid was added in 029. The WorkloadsBase
columns and progress were never added via migration, causing SQLAlchemy
INSERT failures in job_service.py when any API call that creates a job entry
is made (trust-create, backup-target-create, etc.).

Revision ID: 030
Revises: 029
Create Date: 2026-08-04
"""
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import TINYINT
from alembic import op
from sqlalchemy.engine import reflection

revision = '030'
down_revision = '029'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    inspect_obj = reflection.Inspector.from_engine(conn)
    existing_columns = [col['name'] for col in inspect_obj.get_columns('job')]

    if 'created_at' not in existing_columns:
        op.add_column('job', sa.Column('created_at', sa.DateTime, nullable=True))
    if 'updated_at' not in existing_columns:
        op.add_column('job', sa.Column('updated_at', sa.DateTime, nullable=True))
    if 'deleted_at' not in existing_columns:
        op.add_column('job', sa.Column('deleted_at', sa.DateTime, nullable=True))
    if 'deleted' not in existing_columns:
        op.add_column('job', sa.Column('deleted', TINYINT(1), server_default='0', nullable=True))
    if 'version' not in existing_columns:
        op.add_column('job', sa.Column('version', sa.String(255), nullable=True))
    if 'progress' not in existing_columns:
        op.add_column('job', sa.Column('progress', sa.Integer, nullable=True))


def downgrade():
    conn = op.get_bind()
    inspect_obj = reflection.Inspector.from_engine(conn)
    existing_columns = [col['name'] for col in inspect_obj.get_columns('job')]

    for col in ('progress', 'version', 'deleted', 'deleted_at', 'updated_at', 'created_at'):
        if col in existing_columns:
            op.drop_column('job', col)
