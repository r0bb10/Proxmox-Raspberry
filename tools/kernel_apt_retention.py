"""Size-bounded retention for the Pages copy of released kernels."""
from collections import Counter
from functools import cmp_to_key
import subprocess

MAX_SITE_BYTES = 900_000_000
METADATA_RESERVE_BYTES = 8_000_000
MIN_PER_FLAVOUR = 2


def compare_versions(left, right):
    for relation, result in [('lt', -1), ('gt', 1)]:
        comparison = subprocess.run(['dpkg', '--compare-versions', left['kernel'],
                                     relation, right['kernel']], check=False)
        if comparison.returncode == 0:
            return result
        if comparison.returncode != 1:
            raise ValueError('Invalid Debian kernel version')
    return 0


def select_kernels(kernels, budget=MAX_SITE_BYTES - METADATA_RESERVE_BYTES,
                   minimum=MIN_PER_FLAVOUR):
    """Return newest-first retained kernels and oldest-first pruned kernels."""
    if budget <= 0 or minimum < 1:
        raise ValueError('Retention requires a positive budget and minimum')
    ordered = sorted(kernels, key=cmp_to_key(compare_versions))
    counts = Counter(item['flavour'] for item in ordered)
    protected = {flavour: min(minimum, count) for flavour, count in counts.items()}
    # Reserve space for each tiny metapackage as well as the kernel itself.
    total = sum(item['size'] + 16_384 for item in ordered)
    retained, pruned = [], []
    for item in ordered:
        if total > budget and counts[item['flavour']] > protected[item['flavour']]:
            total -= item['size'] + 16_384
            counts[item['flavour']] -= 1
            pruned.append(item)
        else:
            retained.append(item)
    if total > budget:
        raise ValueError('Newest protected kernels exceed the Pages budget; '
                         'refusing to replace the live repository')
    return list(reversed(retained)), pruned
