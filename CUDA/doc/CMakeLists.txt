find_package(Doxygen)

if (DOXYGEN_FOUND)
  add_custom_target (doc ${DOXYGEN_EXECUTABLE} "${gpuNUFFT_SOURCE_DIR}/doc/Doxyfile"
                    WORKING_DIRECTORY ${gpuNUFFT_SOURCE_DIR}/src)
endif()
