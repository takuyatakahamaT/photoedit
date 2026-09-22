"""1つの操作を「無彩色応答 f（輝度→輝度）」と「色への適用方法」に分解して検証する。"""
from __future__ import annotations
import numpy as np
from opmodel import *

def gray_curve(op):
    g=op.grid; m=(np.abs(g[:,0]-g[:,1])<1e-6)&(np.abs(g[:,1]-g[:,2])<1e-6)
    x=luminance(op.y_ref[m]); y=luminance(op.y[m]); o=np.argsort(x); return x[o], y[o]

def make_f(xs, ys, encode=None, decode=None):
    """輝度 f をリニアで定義。encode/decode を与えると、その符号化空間で補間する（曲線の形は同じ、補間だけ変わる）。"""
    if encode is None:
        return lambda v: np.interp(np.clip(v,0,None), xs, ys, left=ys[0], right=ys[-1]) * np.where(v>xs[-1], v/xs[-1], 1.0)
    ex, ey = encode(xs), encode(ys)
    return lambda v: decode(np.interp(encode(np.clip(v,0,None)), ex, ey))

def apply_yratio(x, f):
    Y=luminance(x); return x*(f(Y)/np.clip(Y,1e-9,None))[:,None]

def apply_perchannel(x, f):
    return f(x)

def apply_rgbtone(x, f):
    mx=x.max(-1); mn=x.min(-1); md=x.sum(-1)-mx-mn
    fmx=f(mx); fmn=f(mn); den=np.clip(mx-mn,1e-9,None); frac=np.where(mx-mn>1e-9,(md-mn)/den,0.0)
    fmd=fmn+(fmx-fmn)*frac
    out=np.empty_like(x)
    for c in range(3):
        xc=x[:,c]; out[:,c]=np.where(xc==mx,fmx,np.where(xc==mn,fmn,fmd))
    return out

def rms(a,b,mask): return float(np.sqrt(((a[mask]-b[mask])**2).mean()))

def evaluate(op, methods=("yratio","perchannel-linear","perchannel-srgb","perchannel-pp18","rgbtone-linear","rgbtone-srgb")):
    xs,ys=gray_curve(op); res={}
    m=op.valid & (op.x.max(-1)<0.999)
    f_lin=make_f(xs,ys)
    for name in methods:
        if name=="yratio": pred=apply_yratio(op.y_ref,f_lin)
        elif name=="perchannel-linear": pred=apply_perchannel(op.y_ref,f_lin)
        elif name=="perchannel-srgb": pred=apply_perchannel(op.y_ref,make_f(xs,ys,srgb_encode,srgb_decode))
        elif name=="perchannel-pp18": pred=apply_perchannel(op.y_ref,make_f(xs,ys,pp_encode,pp_decode))
        elif name=="rgbtone-linear": pred=apply_rgbtone(op.y_ref,f_lin)
        elif name=="rgbtone-srgb": pred=apply_rgbtone(op.y_ref,make_f(xs,ys,srgb_encode,srgb_decode))
        else: raise ValueError(name)
        # error in ProPhoto-encoded (perceptual-ish) units ×255
        res[name]=round(255*rms(pp_encode(pred),pp_encode(op.y),m),3)
    return res

def apply_rgbtone_encoded(x, f, enc, dec):
    """RGBTone を符号化空間で行う（max/min へは同じ f、mid の補間比だけ符号化空間）"""
    e=enc(np.clip(x,0,None)); mx=e.max(-1); mn=e.min(-1); md=e.sum(-1)-mx-mn
    fmx=enc(f(dec(mx))); fmn=enc(f(dec(mn)))
    frac=np.where(mx-mn>1e-9,(md-mn)/np.clip(mx-mn,1e-9,None),0.0); fmd=fmn+(fmx-fmn)*frac
    out=np.empty_like(e)
    for c in range(3):
        ec=e[:,c]; out[:,c]=np.where(ec==mx,fmx,np.where(ec==mn,fmn,fmd))
    return dec(out)

def g22_enc(x): return np.power(np.clip(x,0,None),1/2.2)
def g22_dec(x): return np.power(np.clip(x,0,None),2.2)
def evaluate2(op):
    xs,ys=gray_curve(op); f=make_f(xs,ys); m=op.valid&(op.x.max(-1)<0.999); out={}
    for name,fn in [('rgbtone-lin',lambda x:apply_rgbtone(x,f)),('rgbtone-enc-srgb',lambda x:apply_rgbtone_encoded(x,f,srgb_encode,srgb_decode)),('rgbtone-enc-pp18',lambda x:apply_rgbtone_encoded(x,f,pp_encode,pp_decode)),('rgbtone-enc-g22',lambda x:apply_rgbtone_encoded(x,f,g22_enc,g22_dec))]:
        out[name]=round(255*rms(pp_encode(fn(op.y_ref)),pp_encode(op.y),m),3)
    return out
