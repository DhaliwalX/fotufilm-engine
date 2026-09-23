"""Translate the shared scalar Metal camera curves to WGSL (no independent constants)."""
import re


def camera_wgsl(source):
    source = re.sub(r'(\d)f\b', r'\1', source)
    source = re.sub(r'static float (\w+)\(float code\)', r'fn \1(code: f32) -> f32', source)
    source = source.replace('static float decode_curve(float code, uint curve)',
                            'fn decode_curve(code: f32, curve: u32) -> f32')
    source = re.sub(r'(?:const )?float (\w+)\s*;', r'var \1: f32;', source)
    source = re.sub(r'(?:const )?float (\w+)\s*=', r'var \1: f32 =', source)
    source = re.sub(r'=\s*([^;?]+)\?([^;:]+):([^;]+);',
                    lambda m: '= select(' + m[3].strip() + ', ' + m[2].strip() + ', ' + m[1].strip() + ');', source)
    source = re.sub(r'case (\d+): return ([^;]+);', r'case \1u: { return \2; }', source)
    source = re.sub(r'default: return ([^;]+);', r'default: { return \1; }', source)
    if re.search(r'\b(float|static|uint)\b|\?', source):
        raise ValueError('The shared camera curves need an updated WGSL translation.')
    return '// Generated from CameraLogCurve.metalSource; run tools/export-web-video.py.\n' + source + '\n'
