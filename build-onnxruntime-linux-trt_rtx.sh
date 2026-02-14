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
    echo "--- Collecting Static Libs (Ninja Mode) ---"
    
    # 1. 准备目录
    if [ -d "install-static" ]; then rm -rf install-static; fi
    mkdir -p install-static/lib
    
    # 2. 复制头文件
    if [ -d "install/include" ]; then
        cp -r install/include install-static
    fi

    # 3. 扫描需要合并的静态库列表
    # 注意：根据你的日志，库文件就在当前目录 (build-release/Release) 下
    # 我们排除 test, mock, training 等非推理核心库，保留 providers 和核心组件
    # 这里的 grep -v pattern 可以根据你的实际需求增删
    TARGET_LIBS=$(ls libonnxruntime_*.a 2>/dev/null | grep -vE "test|mock|training|eager")
    
    # 必须包含 protobuf 相关的库 (onnx 依赖)，通常它们也会被编出来或者在 _deps 中
    # 如果 protobuf 已经静态链接进 onnxruntime_common 则不需要额外处理
    # 这里我们只关注 onnxruntime 自己的组件
    
    if [ -z "$TARGET_LIBS" ]; then
        echo "❌ Error: No libonnxruntime_*.a found in $(pwd)!"
        ls -F
        # 此时必须退出，因为没有库文件打包也没意义
        exit 1 
    fi

    echo "Found libraries to merge:"
    echo "$TARGET_LIBS"

    # 4. 生成 MRI 脚本用于合并
    MRI_FILE="install-static/libonnxruntime.mri"
    OUTPUT_LIB="install-static/lib/libonnxruntime.a"
    
    echo "create $OUTPUT_LIB" > $MRI_FILE
    
    for lib in $TARGET_LIBS; do
        echo "addlib ${PWD}/$lib" >> $MRI_FILE
    done
    
    echo "save" >> $MRI_FILE
    echo "end" >> $MRI_FILE

    # 5. 执行合并 (带容错回退)
    echo "Attempting to merge libraries into $OUTPUT_LIB ..."
    if ar -M < $MRI_FILE; then
        echo "✅ Merge successful: $OUTPUT_LIB created."
        libs_list="onnxruntime"
    else
        echo "⚠️ Merge failed! Falling back to copying individual libraries..."
        rm -f $OUTPUT_LIB # 清理可能损坏的文件
        
        libs_list=""
        for lib in $TARGET_LIBS; do
            cp "$lib" install-static/lib/
            
            # 提取库名: libonnxruntime_common.a -> onnxruntime_common
            name=${lib#lib}
            name=${name%.a}
            libs_list="${libs_list} ${name}"
        done
        echo "✅ Fallback: Copied individual static libraries."
    fi

    # 6. 生成 CMake Config
    echo "Generating OnnxRuntimeConfig.cmake..."
    {
        echo "set(OnnxRuntime_INCLUDE_DIRS \"\${CMAKE_CURRENT_LIST_DIR}/include\")"
        echo "include_directories(\${OnnxRuntime_INCLUDE_DIRS})"
        echo "link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)"
        # 如果合并成功，这里是 "onnxruntime"
        # 如果回退，这里是 "onnxruntime_common onnxruntime_graph ..."
        echo "set(OnnxRuntime_LIBS $libs_list)" 
    } > install-static/OnnxRuntimeConfig.cmake
    
    # 7. 清理 MRI 临时文件
    rm -f $MRI_FILE
    cp -r libonnxruntime_providers*.so install-static/lib/
    cp -r $TRT_RTX_HOME/lib/libtensorrt_*.so install-static/lib/
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

    cp -r $TRT_RTX_HOME/lib/libtensorrt_*.so install/lib/

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

# 1. 动态修正输出目录路径
# 之前的 ../../$DIST_DIR 失败了，说明 output 在更上一层 (通常是 3 层)
# 这里我们直接获取绝对路径，避免相对路径猜测
if [ -d "../../../$DIST_DIR" ]; then
    # 场景: 运行在 Workspace/onnxruntime/build-release/Release
    DIST_ABS_PATH=$(cd "../../../$DIST_DIR" && pwd)
elif [ -d "../../$DIST_DIR" ]; then
    # 场景: 运行在 onnxruntime/build-release/Release (如果是在 onnxruntime 根目录起跑)
    DIST_ABS_PATH=$(cd "../../$DIST_DIR" && pwd)
else
    # Fallback: 尝试直接创建（以防万一）或报错
    echo "⚠️ Warning: Could not find existing output dir at ../../$DIST_DIR or ../../../$DIST_DIR"
    echo "Assuming ../../../$DIST_DIR and creating it..."
    mkdir -p "../../../$DIST_DIR"
    DIST_ABS_PATH=$(cd "../../../$DIST_DIR" && pwd)
fi

echo "Resolved Output Directory: $DIST_ABS_PATH"

# 2. 打包 Shared Library
SHARED_PKG_NAME="onnxruntime-linux-x64-cuda${CUDA_VER}-trt-rtx-shared"
echo "📦 Packaging Shared Libs -> $SHARED_PKG_NAME"

# 清理旧数据并复制
rm -rf "$DIST_ABS_PATH/$SHARED_PKG_NAME"
cp -r install "$DIST_ABS_PATH/$SHARED_PKG_NAME"

# 切换到 output 目录进行压缩 (使用 pushd 避免迷失路径)
pushd "$DIST_ABS_PATH" > /dev/null
7z a "${SHARED_PKG_NAME}.7z" "$SHARED_PKG_NAME"
rm -rf "$SHARED_PKG_NAME" # 压缩后删除文件夹
popd > /dev/null

# 3. 打包 Static Library
STATIC_PKG_NAME="onnxruntime-linux-x64-cuda${CUDA_VER}-trt-rtx-static"
echo "📦 Packaging Static Libs -> $STATIC_PKG_NAME"

# 清理旧数据并复制
rm -rf "$DIST_ABS_PATH/$STATIC_PKG_NAME"
cp -r install-static "$DIST_ABS_PATH/$STATIC_PKG_NAME"

# 切换到 output 目录进行压缩
pushd "$DIST_ABS_PATH" > /dev/null
7z a "${STATIC_PKG_NAME}.7z" "$STATIC_PKG_NAME"
rm -rf "$STATIC_PKG_NAME"
popd > /dev/null

# 4. 打包 Wheel
echo "📦 Copying Wheels..."
# Wheel 文件通常在 dist 目录下
if ls dist/*.whl 1> /dev/null 2>&1; then
    cp dist/*.whl "$DIST_ABS_PATH/"
else
    echo "⚠️ No wheels found in dist/"
fi

# 退出构建目录 build-release/Release
popd 

echo "=== All Done ==="
ls -l "$DIST_ABS_PATH"