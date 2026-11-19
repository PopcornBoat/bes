"""Pure numeric operations for a fixed-coordinate Gaussian ES diagnostic."""
import math

def antithetic_gradient(directions, plus, minus, sigma):
    if sigma<=0 or not directions or len(directions)!=len(plus) or len(plus)!=len(minus):
        raise ValueError("Invalid paired directions or noise scale")
    width=len(directions[0])
    if any(len(u)!=width for u in directions):
        raise ValueError("Directions must share coordinates")
    m=len(directions)
    return [sum((p-n)*u[j] for u,p,n in zip(directions,plus,minus))/(2*m*sigma)
            for j in range(width)]

def norm(vector):
    return math.sqrt(sum(x*x for x in vector))

def step_for_gradient(gradient,rms_step):
    rms=norm(gradient)/math.sqrt(max(1,len(gradient)))
    return [rms_step*x/rms for x in gradient] if rms>1e-12 else [0.0]*len(gradient)

def matched_random_step(rng,reference):
    value=[rng.gauss(0,1) for _ in reference]
    length=norm(value)
    return [x*norm(reference)/length for x in value] if length else [0.0]*len(reference)

def physical_patch(ids,normalized,parameters):
    # These are actual existing constants. Operand/index types remain untouched.
    return [[i,float(parameters[i]["value"]+parameters[i]["unit"]*x)]
            for i,x in zip(ids,normalized) if abs(x)>1e-14]

