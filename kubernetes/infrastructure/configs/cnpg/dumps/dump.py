import datetime
import os
import subprocess
import sys

KEEP_PER_DATABASE = 30
PREFIX = "dumps"
SUFFIX = ".gpg"
SKIPPED_DATABASES = ("postgres", "app")
LIST_DATABASES = "select datname from pg_database where datallowconn and not datistemplate order by datname"


def primary_fingerprints(listing):
    fingerprints = []
    previous = None
    for line in listing.splitlines():
        fields = line.split(":")
        if fields[0] == "fpr" and previous == "pub":
            fingerprints.append(fields[9])
        previous = fields[0]
    return fingerprints


def import_recipient(key_file, fingerprint):
    os.makedirs(os.environ["GNUPGHOME"], mode=0o700, exist_ok=True)
    subprocess.run(["gpg", "--batch", "--quiet", "--import", key_file], check=True)
    listing = subprocess.run(
        ["gpg", "--batch", "--with-colons", "--list-keys"], check=True, capture_output=True, text=True
    ).stdout
    found = primary_fingerprints(listing)
    if found != [fingerprint]:
        raise SystemExit(f"{key_file} holds the keys {found}, expected exactly {fingerprint}")


def encrypt_command(fingerprint):
    return ["gpg", "--batch", "--trust-model", "always", "--recipient", fingerprint, "--encrypt"]


def dump_database(s3, bucket, key, dump_command, encrypt):
    dump = subprocess.Popen(dump_command, stdout=subprocess.PIPE)
    encryption = subprocess.Popen(encrypt, stdin=dump.stdout, stdout=subprocess.PIPE)
    dump.stdout.close()
    try:
        s3.upload_fileobj(encryption.stdout, bucket, key)
    except Exception as error:
        for process in (dump, encryption):
            process.kill()
            process.wait()
        print(f"{key}: upload failed: {error}", file=sys.stderr)
        s3.delete_object(Bucket=bucket, Key=key)
        return False
    finally:
        encryption.stdout.close()
    codes = (dump.wait(), encryption.wait())
    if codes != (0, 0):
        print(f"{key}: pg_dump exited {codes[0]} and gpg {codes[1]}, removing the upload", file=sys.stderr)
        s3.delete_object(Bucket=bucket, Key=key)
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
    bucket = os.environ["S3_BUCKET"]
    import_recipient(os.environ["RECIPIENT_FILE"], fingerprint)
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
    date = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")
    failed = []
    for database in databases:
        key = f"{PREFIX}/{database}/{date}{SUFFIX}"
        if dump_database(s3, bucket, key, ["pg_dump", "--format=custom", "--dbname", database], encrypt_command(fingerprint)):
            print(f"uploaded {key}")
            prune(s3, bucket, f"{PREFIX}/{database}/", KEEP_PER_DATABASE)
        else:
            failed.append(database)
    if failed:
        raise SystemExit(f"dumps failed for {', '.join(failed)}")


if __name__ == "__main__":
    main()
