#![cfg_attr(not(any(test, feature = "service-model")), no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(all(feature = "service-model", target_os = "none"))]
compile_error!("the test-only service-model feature is forbidden for target firmware");

#[cfg(not(any(test, feature = "service-model")))]
use core::panic::PanicInfo;
use core::{ffi::c_void, mem, ptr, slice};

#[allow(dead_code)]
mod graph {
    include!(env!("MICROBLOSSOM_R5_GRAPH_MODULE"));
}

mod decoder;
pub mod materializer;

#[cfg(feature = "service-model")]
mod software_accelerator;

pub const MICROBLOSSOM_DECODE_OK: u16 = 0;
pub const MICROBLOSSOM_DECODE_INVALID_SYNDROME: u16 = 2;
pub const MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE: u16 = 3;
pub const MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE: u16 = 4;
pub const MAX_MMIO_OPERATIONS: u32 = 4096;

const ABI_VERSION: u32 = 3;
const GRAPH_IDENTITY_BYTES: usize = 32;
const GRAPH_IDENTITY: [u8; GRAPH_IDENTITY_BYTES] = graph::GRAPH_IDENTITY;
const VERTEX_COUNT: u16 = graph::VERTEX_COUNT as u16;
const EDGE_COUNT: u16 = graph::EDGE_COUNT as u16;
const MAX_DEFECTS: u16 = graph::MAX_DEFECTS as u16;
const MAX_CORRECTION_EDGES: u16 = graph::MAX_CORRECTION_EDGES as u16;

pub type MicroblossomRustRead64 =
    unsafe extern "C" fn(context: *mut c_void, offset: u16, value: *mut u64) -> u16;
pub type MicroblossomRustWrite64 = unsafe extern "C" fn(
    context: *mut c_void,
    offset: u16,
    value: u64,
    strobe: u8,
) -> u16;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MicroblossomRustMmio {
    pub context: *mut c_void,
    pub read64: Option<MicroblossomRustRead64>,
    pub write64: Option<MicroblossomRustWrite64>,
}

impl MicroblossomRustMmio {
    pub const fn empty() -> Self {
        Self {
            context: ptr::null_mut(),
            read64: None,
            write64: None,
        }
    }
}

#[repr(C)]
pub struct MicroblossomRustServiceContract {
    pub abi_version: u32,
    pub decode_ok_status: u16,
    pub vertex_count: u16,
    pub edge_count: u16,
    pub max_defects: u16,
    pub max_correction_edges: u16,
    pub max_mmio_operations: u16,
    pub graph_identity: [u8; GRAPH_IDENTITY_BYTES],
    pub service_workspace_bytes: u32,
    pub service_workspace_alignment: u32,
    pub primal_workspace_bytes: u32,
    pub dual_workspace_bytes: u32,
    pub materializer_workspace_bytes: u32,
    pub defect_workspace_bytes: u32,
    pub matching_workspace_bytes: u32,
}

const _: [(); 76] = [(); mem::size_of::<MicroblossomRustServiceContract>()];
const _: () = assert!(graph::VERTEX_COUNT != 0);
const _: () = assert!(graph::EDGE_COUNT != 0);
const _: () = assert!(graph::MAX_DEFECTS <= graph::NONVIRTUAL_VERTEX_COUNT);
const _: () = assert!(graph::MAX_CORRECTION_EDGES <= graph::EDGE_COUNT);
const _: () = assert!(MAX_MMIO_OPERATIONS <= u16::MAX as u32);

#[no_mangle]
pub static microblossom_rust_service_contract: MicroblossomRustServiceContract =
    MicroblossomRustServiceContract {
        abi_version: ABI_VERSION,
        decode_ok_status: MICROBLOSSOM_DECODE_OK,
        vertex_count: VERTEX_COUNT,
        edge_count: EDGE_COUNT,
        max_defects: MAX_DEFECTS,
        max_correction_edges: MAX_CORRECTION_EDGES,
        max_mmio_operations: MAX_MMIO_OPERATIONS as u16,
        graph_identity: GRAPH_IDENTITY,
        service_workspace_bytes: decoder::SERVICE_WORKSPACE_BYTES as u32,
        service_workspace_alignment: decoder::SERVICE_WORKSPACE_ALIGNMENT as u32,
        primal_workspace_bytes: decoder::PRIMAL_WORKSPACE_BYTES as u32,
        dual_workspace_bytes: decoder::DUAL_WORKSPACE_BYTES as u32,
        materializer_workspace_bytes: decoder::MATERIALIZER_WORKSPACE_BYTES as u32,
        defect_workspace_bytes: decoder::DEFECT_WORKSPACE_BYTES as u32,
        matching_workspace_bytes: decoder::MATCHING_WORKSPACE_BYTES as u32,
    };

/// Runs the graph-bound primal solver through a callback-backed seven-register
/// accelerator aperture. Outputs are cleared before any validation or MMIO and
/// remain empty unless decode, correction materialization, and final reset all
/// complete successfully.
///
/// # Safety
///
/// `mmio`, `correction_count`, and `operations` must point to aligned readable
/// or writable objects of their declared types. `defects_le` must be readable
/// for `2 * defect_count` bytes when `defect_count` is nonzero.
/// `correction_edges` must be aligned and writable for `correction_capacity`
/// `u16` elements. All pointed-to objects must remain valid and non-aliasing for
/// the duration of the call, and callbacks must obey the same synchronous
/// lifetime.
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_service_decode(
    mmio: *const MicroblossomRustMmio,
    defects_le: *const u8,
    defect_count: u16,
    correction_edges: *mut u16,
    correction_capacity: u16,
    correction_count: *mut u16,
    operations: *mut u16,
) -> u16 {
    if !correction_count.is_null() && is_aligned(correction_count) {
        unsafe { correction_count.write(0) };
    }
    if !operations.is_null() && is_aligned(operations) {
        unsafe { operations.write(0) };
    }

    let clear_capacity = usize::from(correction_capacity).min(graph::MAX_CORRECTION_EDGES);
    if !correction_edges.is_null() && is_aligned(correction_edges) {
        let mut index = 0usize;
        while index < clear_capacity {
            unsafe { correction_edges.add(index).write(0) };
            index += 1;
        }
    }

    if mmio.is_null()
        || !is_aligned(mmio)
        || correction_count.is_null()
        || !is_aligned(correction_count)
        || operations.is_null()
        || !is_aligned(operations)
        || correction_edges.is_null()
        || !is_aligned(correction_edges)
        || usize::from(correction_capacity) != graph::MAX_CORRECTION_EDGES
        || usize::from(defect_count) > graph::MAX_DEFECTS
        || (defect_count != 0 && defects_le.is_null())
    {
        return MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE;
    }

    let defect_bytes = usize::from(defect_count) * 2;
    let defects = if defect_bytes == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(defects_le, defect_bytes) }
    };
    let corrections =
        unsafe { slice::from_raw_parts_mut(correction_edges, graph::MAX_CORRECTION_EDGES) };
    let outcome = decoder::decode(
        unsafe { mmio.read() },
        defects,
        usize::from(defect_count),
        corrections,
    );
    if outcome.status == MICROBLOSSOM_DECODE_OK {
        if outcome.correction_count > graph::MAX_CORRECTION_EDGES {
            clear_edges(corrections);
            unsafe {
                operations.write(outcome.operations);
            }
            return MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE;
        }
        unsafe {
            correction_count.write(outcome.correction_count as u16);
            operations.write(outcome.operations);
        }
    } else {
        clear_edges(corrections);
        unsafe {
            correction_count.write(0);
            operations.write(outcome.operations);
        }
    }
    outcome.status
}

fn clear_edges(edges: &mut [u16]) {
    for edge in edges {
        *edge = 0;
    }
}

fn is_aligned<T>(pointer: *const T) -> bool {
    (pointer as usize) % mem::align_of::<T>() == 0
}

#[cfg(not(any(test, feature = "service-model")))]
#[panic_handler]
fn panic_abort(_information: &PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}

#[cfg(test)]
static TEST_DECODE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
fn test_decode_guard() -> std::sync::MutexGuard<'static, ()> {
    TEST_DECODE_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod callback_oracle;

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn reject_read(
        _context: *mut c_void,
        _offset: u16,
        _value: *mut u64,
    ) -> u16 {
        1
    }

    unsafe extern "C" fn reject_write(
        _context: *mut c_void,
        _offset: u16,
        _value: u64,
        _strobe: u8,
    ) -> u16 {
        1
    }

    #[test]
    fn decoder_boundary_is_fail_closed() {
        let _guard = test_decode_guard();
        let defects = [0u8, 0u8];
        let mut edges = [0x55aau16; graph::MAX_CORRECTION_EDGES];
        let mut edge_count = 7u16;
        let mut operations = 9u16;
        let mut context = 0u8;
        let mmio = MicroblossomRustMmio {
            context: (&mut context as *mut u8).cast(),
            read64: Some(reject_read),
            write64: Some(reject_write),
        };
        let status = unsafe {
            microblossom_rust_service_decode(
                &mmio,
                defects.as_ptr(),
                1,
                edges.as_mut_ptr(),
                edges.len() as u16,
                &mut edge_count,
                &mut operations,
            )
        };
        assert_eq!(status, MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
        assert_ne!(status, MICROBLOSSOM_DECODE_OK);
        assert_eq!(edge_count, 0);
        assert_eq!(operations, 1);
        assert!(edges.iter().all(|&edge| edge == 0));
    }

    #[test]
    fn contract_is_graph_bound() {
        assert_eq!(microblossom_rust_service_contract.abi_version, ABI_VERSION);
        assert_eq!(
            microblossom_rust_service_contract.decode_ok_status,
            MICROBLOSSOM_DECODE_OK
        );
        assert_eq!(
            microblossom_rust_service_contract.graph_identity,
            GRAPH_IDENTITY
        );
        assert_eq!(
            microblossom_rust_service_contract.max_mmio_operations,
            MAX_MMIO_OPERATIONS as u16
        );
        assert!(microblossom_rust_service_contract.max_defects <= VERTEX_COUNT);
        assert!(microblossom_rust_service_contract.max_correction_edges <= EDGE_COUNT);
    }
}
