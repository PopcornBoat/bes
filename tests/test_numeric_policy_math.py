"""Focused tests of directional estimates; no official interactions."""
from pathlib import Path
import random
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from numeric_policy_math import antithetic_gradient,step_for_gradient,matched_random_step,physical_patch,norm
from numeric_policy_tuning import sx

class NumericPolicyTests(unittest.TestCase):
    def test_quadratic_known_gradient(self):
        rng=random.Random(719)
        x=[0.3,-0.5,0.8,-1.0];target=[1.,2.,-1.,0.5];sigma=0.2
        def score(point):return -sum((a-b)**2 for a,b in zip(point,target))
        u=[[rng.gauss(0,1) for _ in x] for _ in range(4096)]
        plus=[score([a+sigma*b for a,b in zip(x,d)]) for d in u]
        minus=[score([a-sigma*b for a,b in zip(x,d)]) for d in u]
        estimate=antithetic_gradient(u,plus,minus,sigma)
        truth=[2*(b-a) for a,b in zip(x,target)]
        cosine=sum(a*b for a,b in zip(estimate,truth))/(norm(estimate)*norm(truth))
        self.assertGreater(cosine,0.999)
        self.assertLess(norm([a-b for a,b in zip(estimate,truth)])/norm(truth),0.08)

    def test_flat_objective_has_no_fabricated_direction(self):
        g=antithetic_gradient([[1.,0.],[-1.,2.]],[3.,3.],[3.,3.],0.1)
        self.assertEqual(g,[0.,0.])
        self.assertEqual(step_for_gradient(g,0.5),[0.,0.])

    def test_controls_match_step_length(self):
        forward=step_for_gradient([1.,-3.,2.],0.5)
        control=matched_random_step(random.Random(3),forward)
        self.assertAlmostEqual(norm(forward),norm(control),places=12)

    def test_only_selected_coordinates_are_patched(self):
        parameters={5:dict(value=20.,unit=2.),9:dict(value=1.,unit=0.1)}
        self.assertEqual(physical_patch([5,9],[-1.,0.],parameters),[[5,18.]])

    def test_cl_numbers_keep_double_precision(self):
        self.assertEqual(sx(20.125),"20.125d0")
        self.assertIn("d",sx(1e-16))
        self.assertNotIn("e-",sx(1e-16))
        with self.assertRaises(ValueError):sx(float("nan"))

if __name__=="__main__":unittest.main()

