import unittest

from kernel_apt_retention import select_kernels


def kernel(version, flavour='v8', size=100_000_000):
    return {'kernel': f'6.18.{version}-rpi-{flavour}', 'flavour': flavour, 'size': size}


class RetentionTests(unittest.TestCase):
    def test_below_budget_keeps_everything(self):
        items = [kernel(53), kernel(54), kernel(57, '2712')]
        kept, pruned = select_kernels(items)
        self.assertEqual(len(kept), 3)
        self.assertEqual(pruned, [])

    def test_drops_oldest_first(self):
        kept, pruned = select_kernels([kernel(v) for v in [99, 9, 100, 10]], budget=250_000_000)
        self.assertEqual([x['kernel'] for x in kept], ['6.18.100-rpi-v8', '6.18.99-rpi-v8'])
        self.assertEqual([x['kernel'] for x in pruned], ['6.18.9-rpi-v8', '6.18.10-rpi-v8'])

    def test_protects_each_flavour_not_just_latest_overall(self):
        items = [kernel(53, '2712'), kernel(54, '2712'), kernel(55), kernel(56), kernel(57)]
        kept, pruned = select_kernels(items, budget=450_000_000)
        self.assertEqual([x['kernel'] for x in pruned], ['6.18.55-rpi-v8'])
        self.assertEqual(len(kept), 4)

    def test_newest_version_fits_by_removing_older_ones(self):
        items = [kernel(v, f) for v in range(50, 64) for f in ['v8', '2712']]
        kept, pruned = select_kernels(items)
        self.assertLessEqual(sum(x['size'] + 16_384 for x in kept), 892_000_000)
        self.assertEqual({x['kernel'] for x in kept[:2]}, {'6.18.63-rpi-v8', '6.18.63-rpi-2712'})
        self.assertTrue(pruned)

    def test_single_pi5_release_is_protected(self):
        kept, pruned = select_kernels([kernel(1, '2712')] + [kernel(v) for v in range(50, 55)],
                                      budget=350_000_000)
        self.assertIn('6.18.1-rpi-2712', [x['kernel'] for x in kept])
        self.assertEqual(len(pruned), 3)

    def test_impossible_budget_fails_safely(self):
        with self.assertRaisesRegex(ValueError, 'protected kernels exceed'):
            select_kernels([kernel(56), kernel(57)], budget=150_000_000)

    def test_metapackage_space_counts_towards_budget(self):
        kept, pruned = select_kernels([kernel(v, size=100) for v in [55, 56, 57]], budget=33_000)
        self.assertEqual(len(kept), 2)
        self.assertEqual(len(pruned), 1)


if __name__ == '__main__':
    unittest.main()
