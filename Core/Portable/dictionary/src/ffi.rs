use crate::{Error, Input, MAX_SOURCE_BYTES, Result, SourceSpec};
use std::{collections::BTreeMap, panic::catch_unwind, ptr, slice};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Bytes {
    data: *const u8,
    len: usize,
}
impl Bytes {
    fn borrowed(data: &[u8]) -> Self {
        Self {
            data: if data.is_empty() {
                ptr::null()
            } else {
                data.as_ptr()
            },
            len: data.len(),
        }
    }
    unsafe fn read<'a>(self, limit: usize) -> Result<&'a [u8]> {
        if self.len > limit || (self.len != 0 && self.data.is_null()) {
            return Err(Error::new("bridge-input"));
        }
        if self.len == 0 {
            return Ok(&[]);
        }
        // The C caller guarantees the lifetime and readable extent of this buffer.
        Ok(unsafe { slice::from_raw_parts(self.data, self.len) })
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RawInput {
    receipt: Bytes,
    data: Bytes,
}
impl RawInput {
    unsafe fn owned(self) -> Result<Input> {
        let receipt = serde_json::from_slice(unsafe { self.receipt.read(16_384)? })
            .map_err(|_| Error::new("bridge-json"))?;
        Ok(Input {
            receipt,
            data: unsafe { self.data.read(MAX_SOURCE_BYTES)? }.to_vec(),
        })
    }
}

pub struct Output {
    files: Vec<(String, Vec<u8>)>,
    error: Vec<u8>,
}
fn boundary(work: impl FnOnce() -> Result<BTreeMap<String, Vec<u8>>>) -> *mut Output {
    let result = catch_unwind(std::panic::AssertUnwindSafe(work))
        .unwrap_or_else(|_| Err(Error::new("bridge-panic")));
    let output = match result {
        Ok(files) => Output {
            files: files.into_iter().collect(),
            error: Vec::new(),
        },
        Err(error) => Output {
            files: Vec::new(),
            error:
                serde_json::json!({"code": error.code, "source": error.source, "line": error.line})
                    .to_string()
                    .into_bytes(),
        },
    };
    Box::into_raw(Box::new(output))
}

#[unsafe(no_mangle)]
pub extern "C" fn ifd_catalog() -> Bytes {
    Bytes::borrowed(crate::CATALOG_JSON)
}

#[unsafe(no_mangle)]
pub extern "C" fn ifd_recipe_version() -> u32 {
    crate::RECIPE_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn ifd_maximum_source_bytes() -> usize {
    crate::MAX_SOURCE_BYTES
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_generate(
    catalog: Bytes,
    inputs: *const RawInput,
    count: usize,
    corrections: Bytes,
) -> *mut Output {
    boundary(|| {
        if count > 64 || (count != 0 && inputs.is_null()) {
            return Err(Error::new("bridge-input"));
        }
        let catalog: Vec<SourceSpec> = serde_json::from_slice(unsafe { catalog.read(1_048_576)? })
            .map_err(|_| Error::new("bridge-json"))?;
        let inputs = if count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(inputs, count) }
        };
        let inputs = inputs
            .iter()
            .map(|input| unsafe { input.owned() })
            .collect::<Result<Vec<_>>>()?;
        let generated =
            crate::generate(&inputs, unsafe { corrections.read(1_048_576)? }, &catalog)?;
        let mut manifest = serde_json::to_vec_pretty(&generated.manifest)
            .map_err(|_| Error::new("bridge-json"))?;
        manifest.push(b'\n');
        Ok(BTreeMap::from([
            ("pinyin_simp.dict.yaml".to_owned(), generated.dictionary),
            ("dictionary-manifest.json".to_owned(), manifest),
        ]))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_spelling(dictionary: Bytes) -> *mut Output {
    boundary(|| crate::spelling(unsafe { dictionary.read(MAX_SOURCE_BYTES)? }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_validate(input: RawInput) -> *mut Output {
    boundary(|| {
        crate::validate(&unsafe { input.owned()? })?;
        Ok(BTreeMap::new())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_result_error(result: *const Output) -> Bytes {
    Bytes::borrowed(&unsafe { &*result }.error)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_result_count(result: *const Output) -> usize {
    unsafe { &*result }.files.len()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_result_name(result: *const Output, index: usize) -> Bytes {
    Bytes::borrowed(
        unsafe { &*result }
            .files
            .get(index)
            .map_or(&[], |(name, _)| name.as_bytes()),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_result_data(result: *const Output, index: usize) -> Bytes {
    Bytes::borrowed(
        unsafe { &*result }
            .files
            .get(index)
            .map_or(&[], |(_, data)| data),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifd_result_free(result: *mut Output) {
    if !result.is_null() {
        drop(unsafe { Box::from_raw(result) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn error(result: *mut Output) -> String {
        let error = unsafe { ifd_result_error(result).read(16_384) }.unwrap();
        let value: serde_json::Value = serde_json::from_slice(error).unwrap();
        assert_eq!(unsafe { ifd_result_count(result) }, 0);
        let code = value["code"].as_str().unwrap().to_owned();
        unsafe { ifd_result_free(result) };
        code
    }

    #[test]
    fn invalid_requests_and_panic_containment() {
        unsafe {
            let empty = Bytes::borrowed(&[]);
            assert_eq!(error(ifd_spelling(empty)), "source-format");
            assert_eq!(
                error(ifd_spelling(Bytes {
                    data: ptr::null(),
                    len: 1
                })),
                "bridge-input"
            );
            assert_eq!(
                error(ifd_spelling(Bytes {
                    data: ptr::null(),
                    len: usize::MAX
                })),
                "bridge-input"
            );
            assert_eq!(
                error(ifd_generate(empty, ptr::null(), 1, empty)),
                "bridge-input"
            );
            assert_eq!(
                error(ifd_generate(empty, ptr::null(), 65, empty)),
                "bridge-input"
            );
            assert_eq!(
                error(ifd_generate(empty, ptr::null(), 0, empty)),
                "bridge-json"
            );
            assert_eq!(
                error(ifd_generate(Bytes::borrowed(b"[]"), ptr::null(), 0, empty)),
                "source-set"
            );
            assert_eq!(
                error(boundary(|| panic!("test panic boundary"))),
                "bridge-panic"
            );
            ifd_result_free(ptr::null_mut());
        }
    }

    #[test]
    fn generation_matches_direct_calls_for_all_contract_cases() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../fixtures/cases.json")).unwrap();
        for case in cases {
            let mut catalog: Vec<SourceSpec> =
                serde_json::from_str(include_str!("../fixtures/catalog.json")).unwrap();
            let header = case["header"]
                .as_str()
                .unwrap_or("---\nimport_tables: [ignored]\n...\n");
            let inputs: Vec<_> = catalog
                .iter_mut()
                .map(|spec| {
                    let body = case["bodies"][&spec.id]
                        .as_str()
                        .unwrap_or("甲\tjia\t100\n");
                    let data = format!("{header}{body}").into_bytes();
                    spec.pinned_byte_count = data.len();
                    spec.pinned_blob_sha = crate::git_blob(&data);
                    spec.pinned_sha256 = crate::sha256(&data);
                    Input {
                        receipt: spec.pinned_receipt(),
                        data,
                    }
                })
                .collect();
            let corrections = case["corrections"].as_str().unwrap_or("").as_bytes();
            let expected = crate::generate(&inputs, corrections, &catalog);
            let catalog = serde_json::to_vec(&catalog).unwrap();
            let receipts: Vec<_> = inputs
                .iter()
                .map(|i| serde_json::to_vec(&i.receipt).unwrap())
                .collect();
            let raw: Vec<_> = inputs
                .iter()
                .zip(&receipts)
                .map(|(input, receipt)| RawInput {
                    receipt: Bytes::borrowed(receipt),
                    data: Bytes::borrowed(&input.data),
                })
                .collect();
            let output = unsafe {
                ifd_generate(
                    Bytes::borrowed(&catalog),
                    raw.as_ptr(),
                    raw.len(),
                    Bytes::borrowed(corrections),
                )
            };
            drop(raw);
            drop(receipts);
            drop(inputs);
            drop(catalog);
            let output = unsafe { Box::from_raw(output) };
            match expected {
                Ok(expected) => {
                    assert!(output.error.is_empty(), "{}", case["name"]);
                    assert_eq!(output.files.len(), 2);
                    assert_eq!(output.files[1].0, "pinyin_simp.dict.yaml");
                    assert_eq!(output.files[1].1, expected.dictionary);
                    let mut manifest = serde_json::to_vec_pretty(&expected.manifest).unwrap();
                    manifest.push(b'\n');
                    assert_eq!(output.files[0].0, "dictionary-manifest.json");
                    assert_eq!(output.files[0].1, manifest);
                }
                Err(expected) => {
                    assert!(output.files.is_empty());
                    let error: serde_json::Value = serde_json::from_slice(&output.error).unwrap();
                    assert_eq!(
                        error,
                        serde_json::json!({"code": expected.code, "source": expected.source, "line": expected.line})
                    );
                }
            }
        }
    }

    #[test]
    fn owned_spelling_results_and_independent_calls() {
        let threads: Vec<_> = (0..4)
            .map(|_| {
                std::thread::spawn(|| unsafe {
                    let source = b"---\n...\n\xe4\xbd\xa0\tni\t100\n".to_vec();
                    let expected = crate::spelling(&source).unwrap();
                    let result = ifd_spelling(Bytes::borrowed(&source));
                    drop(source);
                    assert_eq!(ifd_result_error(result).len, 0);
                    assert_eq!(ifd_result_count(result), 33);
                    for (index, (name, data)) in expected.iter().enumerate() {
                        assert_eq!(
                            ifd_result_name(result, index).read(1024).unwrap(),
                            name.as_bytes()
                        );
                        assert_eq!(
                            ifd_result_data(result, index)
                                .read(MAX_SOURCE_BYTES)
                                .unwrap(),
                            data
                        );
                    }
                    assert_eq!(ifd_result_data(result, usize::MAX).len, 0);
                    assert_eq!(ifd_result_name(result, usize::MAX).len, 0);
                    ifd_result_free(result);
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
    }
}
