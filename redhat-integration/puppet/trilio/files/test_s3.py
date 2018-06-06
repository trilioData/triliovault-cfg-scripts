from boto.s3.connection import S3Connection
import sys

access_key = sys.argv[1]
secret_key = sys.argv[2]

conn = S3Connection('AKIAIWV6KUOHBMLUQ46A', 'bMTsS3AqSUIMbXxCyyzP8wVB92LRRPBdumoHPsfk')
response = conn.get_all_buckets()
