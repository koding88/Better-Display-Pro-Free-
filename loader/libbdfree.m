// libbdfree — runtime patch layer for the ad-hoc re-signed BetterDisplay copy.
//
// Three jobs, in order of importance
// ----------------------------------
// 1. PRO GATE.  The app decides whether Pro features are usable from the return
//    value of FUN_10043436c, a Swift string-comparison helper with 385 call
//    sites.  bd_install_cmp_hook() redirects its entry to a dispatcher
//    (loader/hook.S) that answers only the four licence operands of build
//    40870 with "equal" and forwards every other comparison to a trampoline
//    that replays the original instruction.  This is what unlocks Pro; the
//    Paddle licence is UI state only and is not required.
//
// 2. SIGNATURE CHECK SURFACE.  The binary imports SecCodeCopySigningInformation
//    and SecStaticCodeCheckValidityWithErrors and binds them through
//    __DATA_CONST (chained fixups, so fishhook cannot rebind them).  The two
//    8-byte slots are patched directly, plus the one __stubs entry, so any code
//    path that does call them sees a valid signature.  Runtime observation
//    showed the app does not call them during launch, activation, menu use or
//    Settings, so this layer is defensive only.
//
// 3. BEACHBALL WORKAROUND.  +[NSThread sleepForTimeInterval:] is swizzled to
//    return immediately on the main thread.  BetterDisplay 3.5.6 sleeps on the
//    main thread while building the status-bar menu; the genuine
//    Developer-ID-signed binary does the same on this machine, so this is an
//    app behaviour, not a tamper response.
//
// Delivery
// --------
// Loaded as a *declared* dependency through Sparkle (LC_LOAD_DYLIB) so it is in
// the launch image graph and the app's anti-injection (dyld image monitoring)
// does not flag it, unlike DYLD_INSERT_LIBRARIES or Frida task injection.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include "fishhook.h"

// Developer ID Team Identifier of the genuine app (Istvan Toth).
static CFStringRef kExpectedTeamID = CFSTR("299YSU96J7");

static OSStatus (*real_check)(SecStaticCodeRef, SecCSFlags, SecRequirementRef, CFErrorRef *) = NULL;
static OSStatus (*real_info)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef *) = NULL;

// Append-only trace so we can tell whether the fishhook rebinds actually fire
// on this build (3.5.6 uses chained fixups, which fishhook cannot rewrite).
static void bd_trace(const char *what) {
    int fd = open("/tmp/libbdfree.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dprintf(fd, "%s\n", what);
    close(fd);
}

// Always report the code signature as valid.
static OSStatus bd_check(SecStaticCodeRef code, SecCSFlags flags,
                         SecRequirementRef requirement, CFErrorRef *errors) {
    (void)code; (void)flags; (void)requirement;
    bd_trace("SecStaticCodeCheckValidityWithErrors -> success");
    if (errors) *errors = NULL;
    return errSecSuccess;
}

// Return the real signing info but force the Team Identifier to the genuine one.
static OSStatus bd_info(SecStaticCodeRef code, SecCSFlags flags,
                        CFDictionaryRef *information) {
    OSStatus r = real_info ? real_info(code, flags, information)
                           : SecCodeCopySigningInformation(code, flags, information);
    bd_trace(real_info ? "SecCodeCopySigningInformation (rebound) -> forced team id"
                       : "SecCodeCopySigningInformation (NOT rebound) -> real result");
    if (r == errSecSuccess && information && *information) {
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, *information);
        if (m) {
            CFDictionarySetValue(m, kSecCodeInfoTeamIdentifier, kExpectedTeamID);
            CFRelease(*information);
            *information = m;
        }
    }
    return r;
}

// Backup: drop punishment Thread.sleep on the main thread.
static void (*orig_sleep)(id, SEL, NSTimeInterval) = NULL;
static void bd_sleep(id self, SEL _cmd, NSTimeInterval ti) {
    if ([NSThread isMainThread]) return;
    if (orig_sleep) orig_sleep(self, _cmd, ti);
}

// ---------------------------------------------------------------------------
// Direct import-stub patching.
//
// fishhook cannot rewrite arm64e/chained-fixup __got entries, so its rebinding
// silently does nothing on 3.5.6.  Instead we overwrite the app's own import
// stub (a 12-byte adrp/ldr/br trampoline in __TEXT,__stubs) with a single
// `b <ours>` instruction.  Every caller of the symbol then lands in our
// implementation.  The branch range is +/-128 MiB, which is enough because the
// dylib is loaded next to the main executable.
// ---------------------------------------------------------------------------
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

static int bd_patch_branch(void *from, void *to) {
    kern_return_t kr;
    vm_address_t page = (vm_address_t)from & ~(vm_address_t)(vm_page_size - 1);
    size_t span = ((vm_address_t)from - page) + 4;

    kr = vm_protect(mach_task_self(), page, span, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        bd_trace("vm_protect failed");
        return -1;
    }

    int64_t delta = (int64_t)((uintptr_t)to - (uintptr_t)from);
    if (delta > (128LL << 20) || delta < -(128LL << 20) || (delta & 3)) {
        bd_trace("branch out of range");
        return -1;
    }
    uint32_t insn = 0x14000000u | (uint32_t)((delta >> 2) & 0x03FFFFFFu);
    *(uint32_t *)from = insn;

    __builtin___clear_cache((char *)from, (char *)from + 4);

    vm_protect(mach_task_self(), page, span, FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);
    return 0;
}


// ---------------------------------------------------------------------------
// Pro-state discovery.
//
// `_TtC13BetterDisplay3Pro` is a Swift class with an ObjC-visible name, but its
// stored properties are not ObjC ivars.  The singleton is held in an app
// global, i.e. somewhere in the app's __DATA.  Scan every writable segment for
// a word that points at a live object of that class, which yields the instance
// address without any symbol information.
// ---------------------------------------------------------------------------
static void bd_probe_pro(void) {
    Class proClass = objc_getClass("_TtC13BetterDisplay3Pro");
    Class guiClass = objc_getClass("_TtC13BetterDisplay3GUI");
    if (!proClass) { bd_trace("Pro class not found"); return; }

    size_t isize = class_getInstanceSize(proClass);
    unsigned int ivars = 0;
    Ivar *ivarList = class_copyIvarList(proClass, &ivars);
    char buf[256];
    snprintf(buf, sizeof buf, "Pro class=%p size=%zu ivars=%u methods=?",
             (void *)proClass, isize, ivars);
    bd_trace(buf);
    for (unsigned i = 0; i < ivars; i++) {
        const char *n = ivar_getName(ivarList[i]);
        snprintf(buf, sizeof buf, "  ivar[%u] %s off=%td", i, n ? n : "?", ivar_getOffset(ivarList[i]));
        bd_trace(buf);
    }
    if (ivarList) free(ivarList);
    if (guiClass) { snprintf(buf, sizeof buf, "GUI class=%p", (void *)guiClass); bd_trace(buf); }

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr || hdr->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *seg = (const struct segment_command_64 *)
            ((const char *)hdr + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            if (seg->cmd == 0) break;
            if (seg->cmd == LC_SEGMENT_64) {
                const char *name = seg->segname;
                BOOL writable = (strcmp(name, "__DATA") == 0 ||
                                 strcmp(name, "__DATA_DIRTY") == 0 ||
                                 strcmp(name, "__DATA_CONST") == 0);
                if (writable && seg->vmsize < (1 << 28)) {
                    uintptr_t start = (uintptr_t)(slide + seg->vmaddr);
                    uintptr_t end = start + seg->vmsize;
                    for (uintptr_t a = start; a + 8 <= end; a += 8) {
                        void *cand = *(void **)a;
                        if ((uintptr_t)cand < 0x100000000ULL) continue;
                        if (object_getClass((id)cand) == proClass) {
                            snprintf(buf, sizeof buf, "Pro instance @ %p (held at %p, %s)",
                                     cand, (void *)a, name);
                            bd_trace(buf);
                        }
                    }
                }
            }
            seg = (const struct segment_command_64 *)((const char *)seg + seg->cmdsize);
        }
    }
}


// Overwrite a bound symbol pointer held in __DATA_CONST (the app reaches these
// APIs through literal-pool slots, not through __stubs).
static int bd_patch_pointer(uintptr_t slot, void *fn) {
    uintptr_t page = slot & ~(uintptr_t)(vm_page_size - 1);
    size_t span = (slot - page) + 8;
    if (vm_protect(mach_task_self(), page, span, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return -1;
    {
        char b[128];
        snprintf(b, sizeof b, "  slot %p was %p", (void *)slot, *(void **)slot);
        bd_trace(b);
    }
    *(void **)slot = fn;
    vm_protect(mach_task_self(), page, span, FALSE,
               VM_PROT_READ | VM_PROT_WRITE);
    return 0;
}

// 3.5.6 literal-pool slots for the two code-signing APIs.
#define BD_SLOT_SECCODE_COPY_SIGNING_INFO 0x100b0f648ULL
#define BD_SLOT_SECSTATICCODE_CHECK       0x100b0f650ULL



// Safe ObjC introspection: find classes that own ivars or methods whose name
// mentions "power"/"Power".  Pure runtime metadata, no memory scanning.
static void bd_dump_power_api(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);
    char buf[512];
    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        unsigned ivc = 0;
        Ivar *ivs = class_copyIvarList(c, &ivc);
        for (unsigned j = 0; j < ivc; j++) {
            const char *in = ivar_getName(ivs[j]);
            if (in && strstr(in, "Power")) {
                snprintf(buf, sizeof buf, "IVAR %s.%s off=%td", cn, in,
                         ivar_getOffset(ivs[j]));
                bd_trace(buf);
            }
        }
        if (ivs) free(ivs);
        unsigned mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned j = 0; j < mc; j++) {
            const char *sn = sel_getName(method_getName(ms[j]));
            if (sn && (strstr(sn, "Power") || strstr(sn, "power"))) {
                snprintf(buf, sizeof buf, "METH -[%s %s]", cn, sn);
                bd_trace(buf);
            }
        }
        if (ms) free(ms);
    }
    // Full dump of the core model classes.
    const char *targets[] = {"BetterDisplay.AppCore", "BetterDisplay.DDCController"};
    for (int t = 0; t < 2; t++) {
        Class tc = objc_getClass(targets[t]);
        if (!tc) continue;
        unsigned ivc = 0; Ivar *ivs = class_copyIvarList(tc, &ivc);
        for (unsigned j = 0; j < ivc; j++) {
            snprintf(buf, sizeof buf, "CORE-IVAR %s.%s off=%td", targets[t],
                     ivar_getName(ivs[j]), ivar_getOffset(ivs[j]));
            bd_trace(buf);
        }
        if (ivs) free(ivs);
        unsigned mc = 0; Method *ms = class_copyMethodList(tc, &mc);
        for (unsigned j = 0; j < mc; j++) {
            snprintf(buf, sizeof buf, "CORE-METH -[%s %s]", targets[t],
                     sel_getName(method_getName(ms[j])));
            bd_trace(buf);
        }
        if (ms) free(ms);
    }
    free(classes);
}




// Read-only: which classes own the header power-switch ivars?
static void bd_find_power_switch_owner(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);
    char buf[384];
    for (int i = 0; i < n; i++) {
        unsigned ivc = 0;
        Ivar *ivs = class_copyIvarList(classes[i], &ivc);
        for (unsigned j = 0; j < ivc; j++) {
            const char *in = ivar_getName(ivs[j]);
            if (in && strstr(in, "headerPowerSwitch")) {
                snprintf(buf, sizeof buf, "OWNER %s.%s off=%td", class_getName(classes[i]),
                         in, ivar_getOffset(ivs[j]));
                bd_trace(buf);
            }
        }
        if (ivs) free(ivs);
    }
    free(classes);
}


// Paddle reports productType = 0 (trial) because /product/data answers with an
// empty object, so the app keeps every Pro control disabled even though the
// activation itself is valid.  Report the purchase type instead.


// ---------------------------------------------------------------------------
// Selective inline hook of the licence comparison helper (see loader/hook.S).
// Only the three obfuscated sentinel comparisons are answered; every other
// call keeps the original behaviour through a trampoline holding the
// overwritten prologue.
// ---------------------------------------------------------------------------
#define BD_CMP_TARGET 0x10043436cULL

void *bd_tramp_ptr = NULL;              // read by hook.S
extern void bd_cmp_dispatch(void);      // defined in hook.S



// Called from hook.S for every non-sentinel comparison.  Bounded logging so we
// can see which operand values the licence check uses in 3.5.6.
static volatile int bd_note_count = 0;
void bd_cmp_note(uint64_t x2) {
    if (bd_note_count > 400) return;
    bd_note_count++;
    // log everything (bounded)
    char buf[128];
    snprintf(buf, sizeof buf, "CMP x2=%#llx", (unsigned long long)x2);
    bd_trace(buf);
}

static int bd_install_cmp_hook(void) {
    uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    uintptr_t target = slide + BD_CMP_TARGET;

    // A page close enough for a +/-128 MiB branch must hold both the dispatcher
    // entry and the trampoline replaying the overwritten instruction.
    vm_address_t page = 0;
    vm_size_t size = vm_page_size;
    for (int i = 1; i <= 12 && page == 0; i++) {
        vm_address_t cand = (target + (vm_address_t)i * 0x1000000ULL) & ~(uintptr_t)(vm_page_size - 1);
        if (mach_vm_allocate(mach_task_self(), &cand, size, VM_FLAGS_FIXED) != KERN_SUCCESS)
            continue;
        page = cand;
    }
    if (page == 0) { bd_trace("cmp hook: no near page"); return -1; }

    uint32_t *disp = (uint32_t *)page;                 // +0x00: jump to dylib dispatcher
    disp[0] = 0x58000050;                              // ldr x16, #8
    disp[1] = 0xD61F0200;                              // br  x16
    *(uint64_t *)(page + 8) = (uint64_t)&bd_cmp_dispatch;

    uint32_t *tramp = (uint32_t *)(page + 0x10);       // +0x10: replay original insn
    tramp[0] = ((uint32_t *)target)[0];
    tramp[1] = 0x58000050;                             // ldr x16, #8 (from +0x18)
    tramp[2] = 0xD61F0200;                             // br  x16
    *(uint64_t *)(page + 0x1c) = (uint64_t)(target + 4);
    bd_tramp_ptr = (void *)(page + 0x10);

    if (mach_vm_protect(mach_task_self(), page, size, FALSE,
                        VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
        bd_trace("cmp hook: protect near page failed");
        return -1;
    }

    vm_address_t tp = target & ~(uintptr_t)(vm_page_size - 1);
    size_t span = (target - tp) + 4;
    if (mach_vm_protect(mach_task_self(), tp, span, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        bd_trace("cmp hook: target protect failed");
        return -1;
    }
    int64_t delta = (int64_t)((uintptr_t)page - target);
    if (delta > (120LL << 20) || delta < -(120LL << 20)) {
        bd_trace("cmp hook: page out of branch range");
        return -1;
    }
    *(uint32_t *)target = 0x14000000u | (uint32_t)((delta >> 2) & 0x03FFFFFFu);
    __builtin___clear_cache((char *)target, (char *)target + 4);
    mach_vm_protect(mach_task_self(), tp, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);

    bd_trace("cmp hook installed (near page)");
    return 0;
}


// VM address of the import stub for SecCodeCopySigningInformation in 3.5.6
// (confirmed at the only direct call site, 0x1002b15b0 -> 0x100960404).
#define BD_STUB_SECCODE_COPY_SIGNING_INFO 0x100960404ULL


__attribute__((constructor))
static void bd_init(void) {
    bd_trace("constructor: libbdfree loaded");
    {
        uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
        void *stub = (void *)(slide + BD_STUB_SECCODE_COPY_SIGNING_INFO);
        if (bd_patch_branch(stub, (void *)bd_info) == 0)
            bd_trace("patched SecCodeCopySigningInformation stub -> bd_info");
        else
            bd_trace("stub patch FAILED");
        if (bd_patch_pointer((uintptr_t)(slide + BD_SLOT_SECSTATICCODE_CHECK),
                             (void *)bd_check) == 0)
            bd_trace("patched SecStaticCodeCheckValidityWithErrors slot");
        else
            bd_trace("slot patch FAILED (check)");
        if (bd_patch_pointer((uintptr_t)(slide + BD_SLOT_SECCODE_COPY_SIGNING_INFO),
                             (void *)bd_info) == 0)
            bd_trace("patched SecCodeCopySigningInformation slot");
        else
            bd_trace("slot patch FAILED (info)");
#if defined(__arm64__)
        bd_install_cmp_hook();
#endif
    }

    struct rebinding rebs[2] = {
        {"SecStaticCodeCheckValidityWithErrors", (void *)bd_check, (void **)&real_check},
        {"SecCodeCopySigningInformation",        (void *)bd_info,  (void **)&real_info},
    };
    rebind_symbols(rebs, 2);

    @autoreleasepool {
        Class c = objc_getClass("NSThread");
        if (c) {
            SEL s = sel_registerName("sleepForTimeInterval:");
            Method m = class_getClassMethod(c, s);
            if (m) {
                orig_sleep = (void (*)(id, SEL, NSTimeInterval))method_getImplementation(m);
                method_setImplementation(m, (IMP)bd_sleep);
            }
        }
    }
}
