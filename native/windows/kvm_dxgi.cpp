// MeshKVM DXGI capture bridge, Windows 8+, desktop user session only.
// Original implementation; D3D11 desktop duplication, dirty-region GPU copies,
// deterministic COM/Map/ReleaseFrame lifetimes, and a native cursor overlay.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <vector>
#include <new>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include "../common/kvm_pixels.h"
using Microsoft::WRL::ComPtr;
#define API extern "C" __declspec(dllexport)
struct Capture {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIOutputDuplication> duplication;
    ComPtr<ID3D11Texture2D> staging;
    DXGI_OUTPUT_DESC output{};
    DXGI_OUTDUPL_DESC description{};
    std::vector<uint8_t> pixels;
    bool valid=false, separate_cursor=true;
    HDC cursor_dc=nullptr;
    HBITMAP cursor_dib=nullptr;
    HGDIOBJ cursor_old=nullptr;
    void *cursor_bits=nullptr;
    int cursor_w=0,cursor_h=0;
    ~Capture() { drop_cursor(); }
    void drop_cursor() {
        if (cursor_old && cursor_dc) SelectObject(cursor_dc,cursor_old);
        if (cursor_dib) DeleteObject(cursor_dib);
        if (cursor_dc) DeleteDC(cursor_dc);
        cursor_dc=nullptr; cursor_dib=nullptr; cursor_old=nullptr; cursor_bits=nullptr;
        cursor_w=cursor_h=0;
    }
};
static void message(char *out,int cap,const char *text,HRESULT hr=S_OK) {
    if (out && cap>0) std::snprintf(out,(size_t)cap,"%s (0x%08lx)",text,(unsigned long)hr);
}
// Never attach to Winlogon or switch to the secure desktop. Fail closed.
API int kvm_dxgi_desktop_available() {
    HDESK input=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);
    if (!input) return 0;
    WCHAR name[256]={},own[256]={}; DWORD n=0;
    BOOL ok=GetUserObjectInformationW(input,UOI_NAME,name,sizeof(name),&n);
    CloseDesktop(input);
    if (!ok || !GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,own,sizeof(own),&n)) return 0;
    return _wcsicmp(name,own)==0 && _wcsicmp(name,L"Winlogon")!=0;
}
API int kvm_dxgi_abi() { return 1; }
API void kvm_dxgi_close(void *handle) { delete static_cast<Capture*>(handle); }
API int kvm_dxgi_open(uintptr_t monitor,void **out,char *error,int cap) {
    if (!out) return -1;
    *out=nullptr;
    if (!kvm_dxgi_desktop_available()) { message(error,cap,"Interactive desktop unavailable"); return -2; }
    Capture *c=new(std::nothrow) Capture;
    if (!c) return -1;
    HRESULT hr=S_OK; bool found=false;
    ComPtr<IDXGIFactory1> factory;
    hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) { delete c; message(error,cap,"CreateDXGIFactory1",hr); return -1; }
    HMONITOR selected=reinterpret_cast<HMONITOR>(monitor);
    if (!selected) { POINT origin={0,0}; selected=MonitorFromPoint(origin,MONITOR_DEFAULTTOPRIMARY); }
    for (UINT ai=0; !found; ++ai) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(ai,&adapter)==DXGI_ERROR_NOT_FOUND) break;
        if (!adapter) break;
        for (UINT oi=0;;++oi) {
            ComPtr<IDXGIOutput> output;
            if (adapter->EnumOutputs(oi,&output)==DXGI_ERROR_NOT_FOUND) break;
            if (!output) break;
            DXGI_OUTPUT_DESC desc{};
            if (FAILED(output->GetDesc(&desc)) || !desc.AttachedToDesktop || desc.Monitor!=selected) continue;
            ComPtr<IDXGIOutput1> output1;
            hr=output.As(&output1);
            if (FAILED(hr)) break;
            hr=D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,
                &c->device,nullptr,&c->context);
            if (FAILED(hr)) break;
            hr=output1->DuplicateOutput(c->device.Get(),&c->duplication);
            if (FAILED(hr)) break;
            c->output=desc; c->duplication->GetDesc(&c->description); found=true; break;
        }
    }
    if (!found) { message(error,cap,"Desktop duplication unavailable for selected monitor",hr); delete c; return -1; }
    const auto &d=c->description;
    if (!kvm_dimensions(d.ModeDesc.Width,d.ModeDesc.Height) || d.ModeDesc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) {
        message(error,cap,"Unsupported DXGI desktop dimensions/format"); delete c; return -1;
    }
    D3D11_TEXTURE2D_DESC td{};
    td.Width=d.ModeDesc.Width; td.Height=d.ModeDesc.Height; td.MipLevels=td.ArraySize=1;
    td.Format=DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count=1;
    td.Usage=D3D11_USAGE_STAGING; td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr=c->device->CreateTexture2D(&td,nullptr,&c->staging);
    if (FAILED(hr)) { message(error,cap,"Create staging texture",hr); delete c; return -1; }
    *out=c; return 0;
}
struct FrameLease {
    IDXGIOutputDuplication *d; bool held=false;
    explicit FrameLease(IDXGIOutputDuplication *p):d(p) {}
    ~FrameLease() { if (held) d->ReleaseFrame(); }
};
struct MapLease {
    ID3D11DeviceContext *ctx; ID3D11Texture2D *tex; bool held=false;
    MapLease(ID3D11DeviceContext *c,ID3D11Texture2D *t):ctx(c),tex(t) {}
    ~MapLease() { if (held) ctx->Unmap(tex,0); }
};
static bool rect_valid(const RECT &r,UINT w,UINT h) {
    return r.left>=0 && r.top>=0 && r.right>r.left && r.bottom>r.top &&
        (UINT)r.right<=w && (UINT)r.bottom<=h;
}
static bool copy_damage(Capture *c,ID3D11Texture2D *source,const DXGI_OUTDUPL_FRAME_INFO &info) {
    if (!c->valid || !info.TotalMetadataBufferSize || info.TotalMetadataBufferSize>8*1024*1024) return false;
    UINT bytes=0;
    std::vector<RECT> dirty(info.TotalMetadataBufferSize/sizeof(RECT)+1);
    std::vector<DXGI_OUTDUPL_MOVE_RECT> moved(info.TotalMetadataBufferSize/sizeof(DXGI_OUTDUPL_MOVE_RECT)+1);
    if (FAILED(c->duplication->GetFrameDirtyRects((UINT)(dirty.size()*sizeof(RECT)),dirty.data(),&bytes))) return false;
    dirty.resize(bytes/sizeof(RECT));
    if (FAILED(c->duplication->GetFrameMoveRects((UINT)(moved.size()*sizeof(DXGI_OUTDUPL_MOVE_RECT)),moved.data(),&bytes))) return false;
    moved.resize(bytes/sizeof(DXGI_OUTDUPL_MOVE_RECT));
    UINT w=c->description.ModeDesc.Width,h=c->description.ModeDesc.Height;
    for (const auto &r:dirty) if (!rect_valid(r,w,h)) return false;
    for (const auto &m:moved) if (!rect_valid(m.DestinationRect,w,h)) return false;
    auto copy=[&](const RECT &r) {
        D3D11_BOX box={(UINT)r.left,(UINT)r.top,0,(UINT)r.right,(UINT)r.bottom,1};
        // Read the CURRENT desktop at the destination; no CPU move ordering bug.
        c->context->CopySubresourceRegion(c->staging.Get(),0,(UINT)r.left,(UINT)r.top,0,source,0,&box);
    };
    for (const auto &m:moved) copy(m.DestinationRect);
    for (const auto &r:dirty) copy(r);
    return !dirty.empty() || !moved.empty();
}
static void draw_cursor(Capture *c,uint8_t *rgb,int w,int h) {
    if (!c->separate_cursor) return;
    CURSORINFO ci={sizeof(CURSORINFO)}; ICONINFO ii{}; BITMAP bm{};
    if (!GetCursorInfo(&ci) || !(ci.flags&CURSOR_SHOWING) || !ci.hCursor || !GetIconInfo(ci.hCursor,&ii)) return;
    int iw=0,ih=0;
    if (ii.hbmColor && GetObject(ii.hbmColor,sizeof(bm),&bm)) { iw=bm.bmWidth; ih=bm.bmHeight; }
    else if (ii.hbmMask && GetObject(ii.hbmMask,sizeof(bm),&bm)) { iw=bm.bmWidth; ih=bm.bmHeight/2; }
    if (ii.hbmColor) DeleteObject(ii.hbmColor);
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    int sw=c->output.DesktopCoordinates.right-c->output.DesktopCoordinates.left;
    int sh=c->output.DesktopCoordinates.bottom-c->output.DesktopCoordinates.top;
    if (iw<1 || ih<1 || iw>512 || ih>512 || sw<1 || sh<1) return;
    int cw=std::max(1,MulDiv(iw,w,sw)),ch=std::max(1,MulDiv(ih,h,sh));
    int left=MulDiv(ci.ptScreenPos.x-c->output.DesktopCoordinates.left-(int)ii.xHotspot,w,sw);
    int top=MulDiv(ci.ptScreenPos.y-c->output.DesktopCoordinates.top-(int)ii.yHotspot,h,sh);
    if (cw>512 || ch>512 || left>=w || top>=h || left+cw<=0 || top+ch<=0) return;
    if (!c->cursor_dib || c->cursor_w!=cw || c->cursor_h!=ch) {
        c->drop_cursor(); c->cursor_dc=CreateCompatibleDC(nullptr);
        if (!c->cursor_dc) return;
        BITMAPINFO bi{}; bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth=cw; bi.bmiHeader.biHeight=-ch; bi.bmiHeader.biPlanes=1;
        bi.bmiHeader.biBitCount=32; bi.bmiHeader.biCompression=BI_RGB;
        c->cursor_dib=CreateDIBSection(c->cursor_dc,&bi,DIB_RGB_COLORS,&c->cursor_bits,nullptr,0);
        if (!c->cursor_dib || !c->cursor_bits) { c->drop_cursor(); return; }
        c->cursor_old=SelectObject(c->cursor_dc,c->cursor_dib); c->cursor_w=cw; c->cursor_h=ch;
    }
    auto bits=static_cast<uint8_t*>(c->cursor_bits);
    for (int y=0;y<ch;++y) for (int x=0;x<cw;++x) {
        auto dst=bits+((size_t)y*cw+x)*4;
        int dx=x+left,dy=y+top;
        if (dx>=0 && dx<w && dy>=0 && dy<h) {
            const auto src=rgb+((size_t)dy*w+dx)*3;
            dst[0]=src[2]; dst[1]=src[1]; dst[2]=src[0];
        } else dst[0]=dst[1]=dst[2]=0;
        dst[3]=255;
    }
    DrawIconEx(c->cursor_dc,0,0,ci.hCursor,cw,ch,0,nullptr,DI_NORMAL); GdiFlush();
    for (int y=0;y<ch;++y) for (int x=0;x<cw;++x) {
        int dx=x+left,dy=y+top;
        if (dx>=0 && dx<w && dy>=0 && dy<h) {
            const auto src=bits+((size_t)y*cw+x)*4; auto dst=rgb+((size_t)dy*w+dx)*3;
            dst[0]=src[2]; dst[1]=src[1]; dst[2]=src[0];
        }
    }
}
// -2 = desktop/access lost (caller must close/reopen), -1 = other failure.
API int kvm_dxgi_read(void *handle,uint8_t *rgb,size_t capacity,int w,int h,char *error,int cap) {
    Capture *c=static_cast<Capture*>(handle);
    if (!c || !rgb || !kvm_dimensions((uint32_t)w,(uint32_t)h) || (uint64_t)w*h*3>capacity) return -1;
    if (!kvm_dxgi_desktop_available()) return -2;
    try {
        DXGI_OUTDUPL_FRAME_INFO info{}; ComPtr<IDXGIResource> resource;
        FrameLease lease(c->duplication.Get());
        HRESULT hr=c->duplication->AcquireNextFrame(0,&info,&resource);
        if (hr==DXGI_ERROR_ACCESS_LOST || hr==DXGI_ERROR_DEVICE_REMOVED || hr==E_ACCESSDENIED) return -2;
        if (hr!=DXGI_ERROR_WAIT_TIMEOUT && FAILED(hr)) { message(error,cap,"AcquireNextFrame",hr); return -1; }
        if (SUCCEEDED(hr)) {
            lease.held=true;
            if (info.LastMouseUpdateTime.QuadPart) c->separate_cursor=info.PointerPosition.Visible!=FALSE;
            if (!c->valid || info.LastPresentTime.QuadPart) {
                ComPtr<ID3D11Texture2D> texture;
                if (FAILED(resource.As(&texture))) return -1;
                // The acquired texture is the authority for physical buffer
                // dimensions, including rotated outputs or a mode change.
                D3D11_TEXTURE2D_DESC td{}; texture->GetDesc(&td);
                if (!kvm_dimensions(td.Width,td.Height) || td.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) return -1;
                if (td.Width!=c->description.ModeDesc.Width || td.Height!=c->description.ModeDesc.Height) {
                    td.Usage=D3D11_USAGE_STAGING; td.BindFlags=0;
                    td.CPUAccessFlags=D3D11_CPU_ACCESS_READ; td.MiscFlags=0;
                    ComPtr<ID3D11Texture2D> staging;
                    hr=c->device->CreateTexture2D(&td,nullptr,&staging);
                    if (FAILED(hr)) return -1;
                    c->staging=staging; c->description.ModeDesc.Width=td.Width;
                    c->description.ModeDesc.Height=td.Height; c->valid=false;
                }
                if (!copy_damage(c,texture.Get(),info)) c->context->CopyResource(c->staging.Get(),texture.Get());
                D3D11_MAPPED_SUBRESOURCE map{};
                MapLease mapping(c->context.Get(),c->staging.Get());
                hr=c->context->Map(c->staging.Get(),0,D3D11_MAP_READ,0,&map);
                if (FAILED(hr)) { message(error,cap,"Map staging texture",hr); return -1; }
                mapping.held=true;
                UINT sw=c->description.ModeDesc.Width,sh=c->description.ModeDesc.Height;
                if (!map.pData || map.RowPitch<sw*4) return -1;
                c->pixels.resize((size_t)sw*sh*4);
                for (UINT y=0;y<sh;++y) std::memcpy(c->pixels.data()+(size_t)y*sw*4,
                    static_cast<uint8_t*>(map.pData)+(size_t)y*map.RowPitch,(size_t)sw*4);
                c->valid=true;
            }
        }
        if (!c->valid) return 0;
        unsigned rot=0;
        switch(c->description.Rotation) {
            case DXGI_MODE_ROTATION_ROTATE90: rot=1;break;
            case DXGI_MODE_ROTATION_ROTATE180:rot=2;break;
            case DXGI_MODE_ROTATION_ROTATE270:rot=3;break;
            default:break;
        }
        UINT sw=c->description.ModeDesc.Width,sh=c->description.ModeDesc.Height;
        if (!kvm_pixels_rgb(c->pixels.data(),c->pixels.size(),0,(int32_t)sw*4,
            sw,sh,0,0,sw,sh,rot,0,rgb,capacity,(uint32_t)w,(uint32_t)h)) return -1;
        draw_cursor(c,rgb,w,h); return 1;
    } catch (const std::bad_alloc &) { message(error,cap,"DXGI buffer allocation failed"); return -1; }
      catch (...) { message(error,cap,"Unexpected DXGI exception"); return -1; }
}
