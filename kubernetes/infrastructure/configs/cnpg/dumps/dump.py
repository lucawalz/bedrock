import datetime
import os
import subprocess
import sys

KEEP_PER_DATABASE = 30
PREFIX = "dumps"
SUFFIX = ".gpg"
KEY_TIME_FORMAT = "%Y-%m-%dT%H%M%SZ"
RECIPIENT_FILE = "/etc/postgres-dump/recipient.asc"
S3_BUCKET = "bedrock-postgres"
SKIPPED_DATABASES = ("postgres", "app")
LIST_DATABASES = "select datname from pg_database where datallowconn and not datistemplate order by datname"


def import_recipient(key_file, fingerprint):
    os.makedirs(os.environ["GNUPGHOME"], mode=0o700, exist_ok=True)
    listing = subprocess.run(
        ["gpg", "--batch", "--show-keys", "--with-colons", key_file], check=True, capture_output=True, text=True
    ).stdout
    found = []
    previous = None
    for line in listing.splitlines():
        fields = line.split(":")
        if fields[0] == "fpr" and previous == "pub":
            found.append(fields[9])
        previous = fields[0]
    if found != [fingerprint]:
        raise SystemExit(f"{key_file} holds the keys {found}, expected exactly {fingerprint}")
    subprocess.run(["gpg", "--batch", "--quiet", "--import", key_file], check=True)


def object_key(database, moment):
    return f"{PREFIX}/{database}/{moment.strftime(KEY_TIME_FORMAT)}{SUFFIX}"


def discard(s3, bucket, key):
    try:
        s3.delete_object(Bucket=bucket, Key=key)
    except Exception as error:
        print(f"{key}: could not remove the partial upload: {error}", file=sys.stderr)


def dump_database(s3, bucket, key, dump_command, encrypt_command):
    dump = subprocess.Popen(dump_command, stdout=subprocess.PIPE)
    encryption = subprocess.Popen(encrypt_command, stdin=dump.stdout, stdout=subprocess.PIPE)
    dump.stdout.close()
    try:
        s3.upload_fileobj(encryption.stdout, bucket, key)
    except Exception as error:
        for process in (dump, encryption):
            process.kill()
            process.wait()
        print(f"{key}: upload failed: {error}", file=sys.stderr)
        discard(s3, bucket, key)
        return False
    finally:
        encryption.stdout.close()
    codes = (dump.wait(), encryption.wait())
    if codes != (0, 0):
        print(f"{key}: pg_dump exited {codes[0]} and gpg {codes[1]}, removing the upload", file=sys.stderr)
        discard(s3, bucket, key)
        return False
    return True


def prune(s3, bucket, prefix, keep):
    listing = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
    if listing.get("IsTruncated"):
        raise SystemExit(f"{prefix} holds more objects than one listing returns")
    keys = sorted(item["Key"] for item in listing.get("Contents", []) if item["Key"].endswith(SUFFIX))
    for key in keys[:-keep]:
        s3.delete_object(Bucket=bucket, Key=key)
        print(f"pruned {key}")


def main():
    import boto3

    fingerprint = os.environ["RECIPIENT_FINGERPRINT"]
    import_recipient(RECIPIENT_FILE, fingerprint)
    databases = subprocess.run(
        ["psql", "--no-psqlrc", "--tuples-only", "--no-align", "--dbname", "postgres", "--command", LIST_DATABASES],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    databases = [name for name in databases if name and name not in SKIPPED_DATABASES]
    if not databases:
        raise SystemExit("found no databases to dump")
    s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"], region_name="auto")
    encrypt_command = ["gpg", "--batch", "--trust-model", "always", "--recipient", fingerprint, "--encrypt"]
    moment = datetime.datetime.now(datetime.UTC)
    failed = []
    for database in databases:
        key = object_key(database, moment)
        if dump_database(s3, S3_BUCKET, key, ["pg_dump", "--format=custom", "--dbname", database], encrypt_command):
            print(f"uploaded {key}")
            prune(s3, S3_BUCKET, f"{PREFIX}/{database}/", KEEP_PER_DATABASE)
        else:
            failed.append(database)
    if failed:
        raise SystemExit(f"dumps failed for {', '.join(failed)}")


if __name__ == "__main__":
    main()
