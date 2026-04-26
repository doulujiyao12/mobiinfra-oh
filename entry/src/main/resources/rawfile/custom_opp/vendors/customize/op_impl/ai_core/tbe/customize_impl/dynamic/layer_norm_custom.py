
import os, sys
import ctypes
import json
import shutil
from tbe.common.platform import get_soc_spec
from tbe.common.utils import para_check
from tbe.tikcpp import compile_op, replay_op, check_op_cap, generalize_op_params, get_code_channel, OpInfo
from tbe.common.buildcfg import get_default_build_config
from impl.util.platform_adapter import tbe_register
from tbe.common.buildcfg import get_current_build_config
PYF_PATH = os.path.dirname(os.path.realpath(__file__))

DTYPE_MAP = {"float32": ["DT_FLOAT", "float"],
    "float16": ["DT_FLOAT16", "half"],
    "int8": ["DT_INT8", "int8_t"],
    "int16": ["DT_INT16", "int16_t"],
    "int32": ["DT_INT32", "int32_t"],
    "int64": ["DT_INT64", "int64_t"],
    "uint1": ["DT_UINT1", "uint8_t"],
    "uint8": ["DT_UINT8", "uint8_t"],
    "uint16": ["DT_UINT16", "uint16_t"],
    "uint32": ["DT_UINT32", "uint32_t"],
    "uint64": ["DT_UINT64", "uint64_t"],
    "bool": ["DT_BOOL", "bool"],
    "double": ["DT_DOUBLE", "double"],
    "dual": ["DT_DUAL", "unknown"],
    "dual_sub_int8": ["DT_DUAL_SUB_INT8", "unknown"],
    "dual_sub_uint8": ["DT_DUAL_SUB_UINT8", "unknown"],
    "string": ["DT_STRING", "unknown"],
    "complex64": ["DT_COMPLEX64", "unknown"],
    "complex128": ["DT_COMPLEX128", "unknown"],
    "qint8": ["DT_QINT8", "unknown"],
    "qint16": ["DT_QINT16", "unknown"],
    "qint32": ["DT_QINT32", "unknown"],
    "quint8": ["DT_QUINT8", "unknown"],
    "quint16": ["DT_QUINT16", "unknown"],
    "resource": ["DT_RESOURCE", "unknown"],
    "string_ref": ["DT_STRING_REF", "unknown"],
    "int4": ["DT_INT4", "int4b_t"],
    "bfloat16": ["DT_BF16", "bfloat16_t"]}

def add_dtype_fmt_option_single(x, x_n, is_ref: bool = False):
    options = []
    x_fmt = x.get("format")
    x_dtype = x.get("dtype")
    x_n_in_kernel = x_n + '_REF' if is_ref else x_n
    options.append("-DDTYPE_{n}={t}".format(n=x_n_in_kernel, t=DTYPE_MAP.get(x_dtype)[1]))
    options.append("-DORIG_DTYPE_{n}={ot}".format(n=x_n_in_kernel, ot=DTYPE_MAP.get(x_dtype)[0]))
    options.append("-DFORMAT_{n}=FORMAT_{f}".format(n=x_n_in_kernel, f=x_fmt))
    return options

def get_dtype_fmt_options(__inputs__, __outputs__):
    options = []
    input_names = ['x', 'gamma', 'beta']
    output_names = ['y']
    unique_param_name_set = set()
    for idx, x in enumerate(__inputs__):
        if x is None:
            continue
        x_n = input_names[idx].upper()
        unique_param_name_set.add(x_n)
        options += add_dtype_fmt_option_single(x, x_n)

    for idx, x in enumerate(__outputs__):
        if x is None:
            continue
        x_n = output_names[idx].upper()
        if x_n in unique_param_name_set:
            options += add_dtype_fmt_option_single(x, x_n, True)
        else:
            options += add_dtype_fmt_option_single(x, x_n)
    return options

def load_dso(so_path):
    try:
        ctypes.CDLL(so_path)
    except OSError as error :
        print(error)
        raise RuntimeError("cannot open %s" %(so_path))
    else:
        print("load so succ ", so_path)

def get_shortsoc_compile_option(compile_option_list: list, shortsoc:str):
    compile_options = []
    if shortsoc in compile_option_list:
        compile_options = compile_option_list[shortsoc]
    elif '__ALLSOC__' in compile_option_list:
        compile_options = compile_option_list['__ALLSOC__']
    return compile_options

def get_kernel_source(src_file, dir_snake, dir_ex):
    src_ex = os.path.join(PYF_PATH, "..", "ascendc", dir_ex, src_file)
    if os.path.exists(src_ex):
        return src_ex
    src = os.path.join(PYF_PATH, "..", "ascendc", dir_snake, src_file)
    if os.path.exists(src):
        return src
    src = os.path.join(PYF_PATH, src_file)
    if os.path.exists(src):
        return src
    return src_ex

def _build_args(x_in__, gamma_in__, beta_in__, y_out_, epsilon, norm_size):
    __inputs__ = []
    for arg in [x_in__, gamma_in__, beta_in__]:
        if arg != None:
            if isinstance(arg, (list, tuple)):
                if len(arg) == 0:
                    continue
                __inputs__.append(arg[0])
            else:
                __inputs__.append(arg)
        else:
            __inputs__.append(arg)
    __outputs__ = []
    for arg in [y_out_]:
        if arg != None:
            if isinstance(arg, (list, tuple)):
                if len(arg) == 0:
                    continue
                __outputs__.append(arg[0])
            else:
                __outputs__.append(arg)
        else:
            __outputs__.append(arg)
    __attrs__ = []
    if epsilon != None:
        attr = {}
        attr["name"] = "epsilon"
        attr["dtype"] = "float"
        attr["value"] = epsilon
        __attrs__.append(attr)
    if norm_size != None:
        attr = {}
        attr["name"] = "norm_size"
        attr["dtype"] = "int"
        attr["value"] = norm_size
        __attrs__.append(attr)
    return __inputs__, __outputs__, __attrs__

@tbe_register.register_operator("LayerNormCustom", trans_bool_to_s8=False)
@para_check.check_op_params(para_check.REQUIRED_INPUT, para_check.REQUIRED_INPUT, para_check.REQUIRED_INPUT, para_check.REQUIRED_OUTPUT, para_check.REQUIRED_ATTR_FLOAT, para_check.REQUIRED_ATTR_INT, para_check.KERNEL_NAME)
def layer_norm_custom(x_in__, gamma_in__, beta_in__, y_out_, epsilon, norm_size, kernel_name="layer_norm_custom", impl_mode=""):
    if get_current_build_config("enable_op_prebuild"):
        return
    __inputs__, __outputs__, __attrs__ = _build_args(x_in__, gamma_in__, beta_in__, y_out_, epsilon, norm_size)
    options = get_dtype_fmt_options(__inputs__, __outputs__)
    options += ["-x", "cce"]
    bisheng = shutil.which("bisheng")
    if bisheng != None:
        bisheng_path = os.path.dirname(bisheng)
        tikcpp_path = os.path.realpath(os.path.join(bisheng_path, "..", "..", "tikcpp"))
        if not os.path.exists(tikcpp_path):
            tikcpp_path = os.path.realpath(os.path.join(bisheng_path, "..", "..", "include", "tikcpp"))
    else:
        tikcpp_path = os.path.realpath("/usr/local/Ascend/latest/compiler/tikcpp")
    options.append("-I" + tikcpp_path)
    options.append("-I" + os.path.join(tikcpp_path, "tikcfw"))
    options.append("-I" + os.path.join(tikcpp_path, "tikcfw", "impl"))
    options.append("-I" + os.path.join(tikcpp_path, "tikcfw", "interface"))
    options.append("-I" + os.path.join(PYF_PATH, "..", "ascendc", "common"))
    options.append("-I" + os.path.join(tikcpp_path, "..", "ai_ddk_lib", "include"))
    options.append("-I" + os.path.join(tikcpp_path, "..", "ai_ddk_lib", "include", "secure"))
    if impl_mode == "high_performance":
        options.append("-DHIGH_PERFORMANCE=1")
    elif impl_mode == "high_precision":
        options.append("-DHIGH_PRECISION=1")
    if get_default_build_config("enable_deterministic_mode") == 1:
        options.append("-DDETEMINISTIC_MODE=1")
    if os.getenv("ENABLE_ASCENDC_NPU_KERNEL_DUMP") == "ENABLE":
        options.append("-DNPU_DUMP=1")
        options.append("-DASCENDC_DUMP=1")

    custom_compile_options = {},
    custom_all_compile_options = {},
    soc_version = get_soc_spec("SOC_VERSION")
    soc_short = get_soc_spec("SHORT_SOC_VERSION").lower()
    custom_compile_options_soc = get_shortsoc_compile_option(custom_compile_options[0], soc_short)
    custom_all_compile_options_soc = get_shortsoc_compile_option(custom_all_compile_options[0], soc_short)
    options += custom_all_compile_options_soc
    options += custom_compile_options_soc

    origin_func_name = "layer_norm_custom"
    ascendc_src_dir_ex = "layer_norm_custom"
    ascendc_src_dir = "layer_norm_custom"
    ascendc_src_file = "layer_norm_custom.cpp"
    src = get_kernel_source(ascendc_src_file, ascendc_src_dir, ascendc_src_dir_ex)

    print("start compile Ascend C operator LayerNormCustom. kernel name is " + kernel_name)
    op_type = "LayerNormCustom"
    code_channel = get_code_channel(src, kernel_name, op_type, options)
    op_info = OpInfo(kernel_name = kernel_name, op_type = op_type, inputs = __inputs__, outputs = __outputs__,\
        attrs = __attrs__, impl_mode = impl_mode, origin_inputs=[x_in__, gamma_in__, beta_in__], origin_outputs = [y_out_], param_type_dynamic = False,\
        mc2_ctx = None, param_type_list = ['required', 'required', 'required', 'required'])
    compile_op(src, origin_func_name, op_info, options, code_channel, '{}')
