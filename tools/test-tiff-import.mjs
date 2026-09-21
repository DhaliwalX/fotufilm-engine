#!/usr/bin/env node
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium, expect } = require('@playwright/test')
const browser = await chromium.launch({channel:'chrome'})
try {
 const page=await browser.newPage()
 const errors=[];page.on('pageerror',e=>errors.push(e.message))
 await page.goto(process.argv[2] || 'http://127.0.0.1:5173/')
 await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/)
 const names=['rgb16-None','rgb16-deflate','rgb16-lzw','rgb16-packbits','rgb16-big','rgb16-planar','rgb16-tiled','rgb16-planar-tiled','rgb16-bigtiff',...Array.from({length:8},(_,i)=>'orientation-'+(i+1)),'gray16-black','gray16-white','rgba16-straight','rgba16-associated','rgb32-linear','rgb8-jpeg','invalid-profile','truncated','gray1-packed','gray2-packed','gray4-packed','palette8','palette-reference']
 const results={}
 for(const name of names){
  const buffer=await readFile(new URL(`../build/tiff-fixtures/${name}.tiff`,import.meta.url))
  results[name]=await page.evaluate(async({bytes,name})=>{
   const {importPhoto}=await import('/src/photo-import.js')
   try {
    const {image,url}=await importPhoto(new File([new Uint8Array(bytes)],name+'.tiff',{type:'image/tiff'}))
    const result={width:image.naturalWidth,height:image.naturalHeight,depth:image.deep.bitDepth,pixels:Array.from(image.linear.data)}
    URL.revokeObjectURL(url);return result
   }catch(error){return {error:error.message}}
  },{bytes:[...buffer],name})
  console.log(name,results[name].error || [results[name].width,results[name].height,results[name].depth])
 }
 const reference=results['rgb16-None'];assert.ok(!reference.error)
 const peak=(a,b)=>{assert.equal(a.length,b.length);return a.reduce((error,v,i)=>Math.max(error,Math.abs(v-b[i])),0)}
 for(const name of names.slice(1,9))assert.deepEqual(results[name],reference,name)
 for(let orientation=1;orientation<=8;orientation++){
  const actual=results['orientation-'+orientation];assert.ok(!actual.error)
  assert.equal(actual.width,orientation>=5?45:70);assert.equal(actual.height,orientation>=5?70:45)
  const expected=new Float32Array(reference.pixels.length)
  for(let y=0;y<45;y++)for(let x=0;x<70;x++){
   const positions=[[x,y],[69-x,y],[69-x,44-y],[x,44-y],[y,x],[44-y,x],[44-y,69-x],[y,69-x]]
   const [ox,oy]=positions[orientation-1];expected.set(reference.pixels.slice((y*70+x)*4,(y*70+x)*4+4),(oy*actual.width+ox)*4)
  }
  assert.deepEqual(actual.pixels,[...expected],'orientation '+orientation)
 }
 assert.deepEqual(results['gray16-white'],results['gray16-black'])
 assert.ok(new Set(results['gray16-black'].pixels.filter((_,i)=>i%4===0)).size>=512,'retain more than 8-bit precision')
 const alpha=results['rgba16-straight'];assert.ok(!alpha.error)
 for(let i=0;i<alpha.pixels.length;i++)if(i%4!==3)assert.ok(Math.abs(alpha.pixels[i]-reference.pixels[i]*32768/65535)<1e-6)
 assert.ok(peak(alpha.pixels,results['rgba16-associated'].pixels)<0.00005)
 assert.ok(Math.max(...results['rgb32-linear'].pixels)>1,'floating TIFF retains HDR values')
 assert.ok(peak(results['rgb8-jpeg'].pixels,reference.pixels)<0.04,'JPEG YCbCr color decoded')
 assert.match(results['invalid-profile'].error,/profile/i)
 assert.ok(results.truncated.error,'truncated TIFF must fail')
 const decode = v => v <= .04045 ? v/12.92 : ((v+.055)/1.055)**2.4
 for(const depth of [1,2,4]) {
  const actual=results[`gray${depth}-packed`];assert.ok(!actual.error)
  assert.equal(actual.width,73);assert.equal(actual.height,5)
  for(let i=0;i<73*5;i++)for(let c=0;c<3;c++)assert.ok(Math.abs(actual.pixels[4*i+c]-decode((i%(1<<depth))/((1<<depth)-1)))<.0001)
 }
 assert.deepEqual(results.palette8.pixels,results['palette-reference'].pixels)
 for(let i=0;i<512;i++)assert.ok(Math.abs(results['gray16-black'].pixels[4*i]-decode((2000+100*i)/65535))<.0001)
 assert.deepEqual(errors,[])
 console.log('TIFF codec, precision, profile, alpha, orientation and invalid-input checks passed')
}finally{await browser.close()}
