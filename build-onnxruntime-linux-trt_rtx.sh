#!/bin/bash
set -e

# ================= Configuration =================
ORT_ROOT=${ORT_PATH:-"onnxruntime"}
TRT_HOME=${TRT_RTX_HOME}
CUDA_VER=${CUDA_VERSION}
CUDA_PATH=${CUDA_PATH}
PYTHON_CMD=${PYTHON_EXEC:-"python"}
PIP_CMD=${PIP_EXEC:-"uv pip"}

# 定义构建目录名称 (与 build.py 参数对应)
BUILD_DIR_NAME="build-release"
# 最终产物输出目录
DIST_DIR="output"

# ================= Helper Functions (来自原始脚本) =================

function is_cmd_exist() {
    retval=""
    if ! command -v $1 >/dev/null 2>&1; then
        retval="false"
    else
        retval="true"
    fi
    echo "$retval"
}

# 原始脚本逻辑：从 link.txt 提取 .a 文件路径
function copy_libs() {
    all_link=$(cat CMakeFiles/onnxruntime.dir/link.txt)
    link=${all_link#*onnxruntime.dir}
    regex="lib.*.a$"
    libs=""
    for var in $link; do
        if [[ ${var} =~ ${regex} ]]; then
            cp ${var} install-static/lib
            name=$(echo $var | grep -E ${regex} -o)
            name=${name#lib}
            name=${name%.a}
            libs="${libs} ${name}"
        fi
    done
    echo "$libs"
}

# 原始脚本逻辑：使用 ar 脚本 (MRI) 合并静态库
function combine_libs_linux() {
    all_link=$(cat CMakeFiles/onnxruntime.dir/link.txt)
    link=${all_link#*onnxruntime.dir}
    regex="lib.*.a$"
    root_path="${PWD}"
    static_path="${PWD}/install-static"
    lib_path="${PWD}/install-static/lib"
    mkdir -p $lib_path
    
    echo "create ${lib_path}/libonnxruntime.a" >${static_path}/libonnxruntime.mri
    for var in $link; do
        if [[ ${var} =~ ${regex} ]]; then
            echo "addlib ${root_path}/${var}" >>${static_path}/libonnxruntime.mri
        fi
    done
    echo "save" >>${static_path}/libonnxruntime.mri
    echo "end" >>${static_path}/libonnxruntime.mri
    
    # 执行合并
    ar -M <${static_path}/libonnxruntime.mri
}

# 核心静态库收集函数
function collect_static_libs() {
    echo "--- Collecting Static Libs ---"
    if [ -d "install-static" ]; then
        rm -r -f install-static
    fi
    mkdir -p install-static/lib

    # 复制头文件
    if [ -d "install/include" ]; then
        cp -r install/include install-static
    fi

    # 检查 link.txt 是否存在 (关键)
    if [ ! -f "CMakeFiles/onnxruntime.dir/link.txt" ]; then
        echo "❌ link.txt is not exist at $(pwd)/CMakeFiles/onnxruntime.dir/link.txt"
        echo "Directory content:"
        ls -F
        exit 1
    fi

    ar_exist=$(is_cmd_exist ar)
    ranlib_exist=$(is_cmd_exist ranlib)
    
    if [ "$ar_exist" == "true" ] && [ "$ranlib_exist" == "true" ]; then
        echo "Using ar merge (combine_libs_linux)..."
        combine_libs_linux
        libs="onnxruntime"
    else
        echo "Using legacy copy (copy_libs)..."
        libs=$(copy_libs)
    fi

    # 生成 CMake Config
    echo "set(OnnxRuntime_INCLUDE_DIRS \"\${CMAKE_CURRENT_LIST_DIR}/include\")" >install-static/OnnxRuntimeConfig.cmake
    echo "include_directories(\${OnnxRuntime_INCLUDE_DIRS})" >>install-static/OnnxRuntimeConfig.cmake
    echo "link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)" >>install-static/OnnxRuntimeConfig.cmake
    echo "set(OnnxRuntime_LIBS $libs)" >>install-static/OnnxRuntimeConfig.cmake

    # 备份 link.txt 用于调试
    cp CMakeFiles/onnxruntime.dir/link.txt install-static/link.log
}

# 共享库收集函数 (简化版，保留基本逻辑)
function collect_shared_lib() {
    echo "--- Collecting Shared Libs ---"
    # 清理不必要的文件
    if [ -d "install/bin" ]; then rm -r -f install/bin; fi
    if [ -d "install/include/onnxruntime" ]; then
        mv install/include/onnxruntime/* install/include
        rm -rf install/include/onnxruntime
    fi
    
    # 生成 Config
    echo "set(OnnxRuntime_INCLUDE_DIRS \"\${CMAKE_CURRENT_LIST_DIR}/include\")" >install/OnnxRuntimeConfig.cmake
    echo "include_directories(\${OnnxRuntime_INCLUDE_DIRS})" >>install/OnnxRuntimeConfig.cmake
    echo "link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)" >>install/OnnxRuntimeConfig.cmake
    echo "set(OnnxRuntime_LIBS onnxruntime)" >>install/OnnxRuntimeConfig.cmake
}

# ================= Main Build Execution =================

mkdir -p $DIST_DIR
# $PIP_CMD -m pip install numpy setuptools wheel packaging
source ./.venv/bin/activate
echo "use tensorrt-rtx in $TRT_RTX_HOME"
ls -laR $TRT_RTX_HOME

cd $ORT_ROOT

echo "Starting build..."
# 注意：这里我们使用 install 前缀，是为了让 collect_static_libs 里能找到 install/include
$PYTHON_CMD tools/ci_build/build.py \
    --build_dir "$BUILD_DIR_NAME" \
    --config Release \
    --parallel \
    --skip_tests \
    --build_shared_lib \
    --build_wheel \
    --cmake_generator "Ninja" \
    --cuda_home "$CUDA_PATH" \
    --use_nv_tensorrt_rtx  \
    --tensorrt_rtx_home "$TRT_RTX_HOME" \
    --compile_no_warning_as_error \
    --allow_running_as_root \
    --cmake_extra_defines \
  CMAKE_INSTALL_PREFIX=./install \
  CMAKE_CXX_FLAGS="-Wno-error=array-bounds"

# 检查构建是否成功
if [ ! -d "$BUILD_DIR_NAME/Release" ]; then
    echo "Build failed, directory not found."
    exit 1
fi

# 进入构建目录 (CMake 产物所在位置)
pushd "$BUILD_DIR_NAME/Release"

# 执行 CMake Install (这一步会生成 ./install 目录，包含头文件和 .so)
cmake --install .

if [ ! -d "install" ]; then
    echo "CMake install failed."
    exit 1
fi

# === 执行你的收集逻辑 ===
collect_shared_lib
collect_static_libs  # 这里会调用 combine_libs_linux 解析当前目录下的 link.txt

# ================= Packaging =================

# 1. 打包 Shared
SHARED_PKG_NAME="onnxruntime-linux-x64-cuda${CUDA_VER}-trt-rtx-shared"
# 将处理好的 install 目录移出来打包
cp -r install ../../$DIST_DIR/$SHARED_PKG_NAME
cd ../../$DIST_DIR
7z a ${SHARED_PKG_NAME}.7z $SHARED_PKG_NAME
rm -rf $SHARED_PKG_NAME

# 2. 打包 Static
STATIC_PKG_NAME="onnxruntime-linux-x64-cuda${CUDA_VER}-trt-rtx-static"
# 回到构建目录找 install-static
cd ../$ORT_ROOT/$BUILD_DIR_NAME/Release
cp -r install-static ../../$DIST_DIR/$STATIC_PKG_NAME
cd ../../$DIST_DIR
7z a ${STATIC_PKG_NAME}.7z $STATIC_PKG_NAME
rm -rf $STATIC_PKG_NAME

# 3. 打包 Wheel
cd ../$ORT_ROOT/$BUILD_DIR_NAME/Release
cp dist/*.whl ../../$DIST_DIR/

popd # 退出 build 目录

echo "=== All Done ==="
ls -l $DIST_DIR