// The prototype's hash2 / vnoise / fbm (reference/inkwood-renderer.html), in
// the shading language -- the GPU twin of scripts/core/noise.gd:
//
//   function hash2(i,j,s){let h=(Math.imul(i,374761393)+Math.imul(j,668265263)+Math.imul(s,1442695041))|0;
//     h=Math.imul(h^(h>>>13),1274126177);h^=h>>>16;return(h>>>0)/4294967296;}
//   function vnoise(x,y,s){...smoothstep-interpolated hash2 at the four corners...}
//   function fbm(x,y,s,o){let v=0,a=.5,f=1,n=0;for(let i=0;i<o;i++){v+=a*vnoise(x*f,y*f,s+i*17);n+=a;a*=.5;f*=2.03;}return v/n;}
//
// THE INTEGER PART IS EXACT: `uint` arithmetic wraps modulo 2^32, which is
// exactly Math.imul's low 32 bits, and uint(int) keeps the two's-complement
// bits, so hash2 returns the same lattice value as the prototype for every
// cell -- up to the final float(h) / 2^32, which fp32 rounds to 24 bits.
// THE FLOAT PART IS NOT BIT-EXACT: the coordinates, the smoothstep and the
// octave sum run in fp32 where the prototype uses doubles. The difference is
// around 1e-6 of the [0, 1) range, far below one 8-bit step, so a tint built
// from it is visually identical; anything that makes a DECISION from noise
// (tree placement, a threshold) must use scripts/core/noise.gd instead.
//
// Include with:  #include "res://scripts/render/shaders/noise.gdshaderinc"

float ink_hash2(int i, int j, int s) {
	uint h = uint(i) * 374761393u + uint(j) * 668265263u + uint(s) * 1442695041u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h = h ^ (h >> 16u);
	return float(h) / 4294967296.0;
}

float ink_vnoise(float x, float y, int s) {
	float xi = floor(x);
	float yi = floor(y);
	float xf = x - xi;
	float yf = y - yi;
	float u = xf * xf * (3.0 - 2.0 * xf);
	float v = yf * yf * (3.0 - 2.0 * yf);
	int ix = int(xi);
	int iy = int(yi);
	float a = ink_hash2(ix, iy, s);
	float b = ink_hash2(ix + 1, iy, s);
	float c = ink_hash2(ix, iy + 1, s);
	float d = ink_hash2(ix + 1, iy + 1, s);
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}

float ink_fbm(float x, float y, int s, int octaves) {
	float v = 0.0;
	float a = 0.5;
	float f = 1.0;
	float n = 0.0;
	for (int i = 0; i < octaves; i++) {
		v += a * ink_vnoise(x * f, y * f, s + i * 17);
		n += a;
		a *= 0.5;
		f *= 2.03;
	}
	return v / n;
}
