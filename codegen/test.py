from pathlib import Path
from collections import Counter
import json
from typing import Any


def pprint(x):
    if isinstance(x, tuple) or isinstance(x, set):
        x = list(x)
    print(json.dumps(x, indent=2))


data = json.loads(
    Path(
        "/var/home/josh/src/lightning-rod/minecraft-data/data/pc/1.21.8/protocol.json"
    ).read_text()
)


# def all_types(data):
#     for k, v in data.items():
#         if k == "types":
#             for kk, vv in v.items():
#                 yield (kk, vv)
#         else:
#             yield from all_types(v)


# things = set()
# names = Counter()
# for k, v in all_types(data):
#     names[k] += 1
#     # assert isinstance(v, list)
#     #
#     # assert len(v) == 2
#     if isinstance(v, str):
#         assert v in ["native", "varint"]
#         continue
#     # assert isinstance(v, list)
#     # assert len(v) == 2
#     # things.add(v[0])
#     # print(f"\n\n====== {k} ========")
#     #
#     if v[0] == "array":
#         print(v[1])
#     #
#     # pprint(v)
#     # pprint(v)
#     #
#     #
# pprint(sorted(things))
# pprint(dict(names.most_common()))
#
# def all_things(data):
#     if isinstance(data, list):
#         for x in data:
#             yield from all_things(x)

#     if isinstance(data, dict):
#         for k, v in data.items():
#             yield from all_things(v)

#     yield data


code = ""


def do_type(name: str, namespaces: list[str], v: Any):
    print(name, namespaces, v)


NATIVE_TYPES = {
    "anonOptionalNbt",
    "anonymousNbt",
    "array",
    "bitfield",
    "bitflags",
    "bool",
    "buffer",
    "container",
    "entityMetadataLoop",
    "f32",
    "f64",
    "i16",
    "i32",
    "i64",
    "i8",
    "option",
    "pstring",
    "registryEntryHolder",
    "registryEntryHolderSet",
    "restBuffer",
    "switch",
    "topBitSetTerminatedArray",
    "u16",
    "u32",
    "u64",
    "u8",
    "UUID",
    "varint",
    "varlong",
    "void",
}

constructors = set()


def recurse(x: Any, namespaces: list[tuple[str, set[str]]]):
    for k, v in x.items():
        if k == "type":
            do_type(k, namespaces, v)
        elif isinstance(v, str):
            assert v in ["native", "varint"]
            if v == "native":
                assert k in NATIVE_TYPES
        elif isinstance(v, list):
            assert len(v) == 2
            type_constructor, args = v
            constructors.add(type_constructor)
            match type_constructor:
                case "container":
                    for field in args:
                        pprint(field)
                        keys = set(field.keys())
                        assert keys == {"name", "type"} or keys == {"anon", "type"}
                case "registryEntryHolderSet":
                    print("A")
                case "array":
                    print("A")
                case "pstring":
                    print("A")
                case "registryEntryHolder":
                    print("A")
                case "bitfield":
                    print("A")
                case "bitflags":
                    print("A")
                case "mapper":
                    print("A")
                case "option":
                    print("A")
                case "buffer":
                    print("A")
                case "entityMetadataLoop":
                    print("A")
                case _:
                    assert False
        else:
            recurse(v, namespaces + [k])


recurse(data, [])
pprint(constructors)
