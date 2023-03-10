/* --------------------------------------------------------------------------
 * Project: Microvascular
 * File: microvascular_gpu.cu
 *
 * Author   : Ali Aghaeifar <ali.aghaeifar@tuebingen.mpg.de>
 * Date     : 10.02.2023
 * Descrip  : simulating BOLD in microvascular network
 * -------------------------------------------------------------------------- */

// compile(lin) :  nvcc microvascular_gpu.cu -Xptxas -v -O3  -arch=compute_86 -code=sm_86  -Xcompiler -fopenmp -o sim_microvascular
// compile(win) :  nvcc microvascular_gpu.cu -Xptxas -v -O3  -arch=compute_86 -code=sm_86  -Xcompiler /openmp -std=c++17 -o sim_microvascular

#include <random>
#include <filesystem>

#include "./common/kernels.h"
#include "./common/reader.h"


#define THREADS_PER_BLOCK  64

using namespace std;

bool simulate(simulation_parameters param, std::map<std::string, std::vector<std::string> > filenames, std::vector<float> sample_length_scales)
{
    std::vector<float> fieldmap;
    std::vector<char> mask;
    // ========== checking GPU(s) ==========
    int32_t device_count;
    checkCudaErrors(cudaGetDeviceCount(&device_count));
    std::cout << "Number of GPU(s): " << device_count << std::endl;
    param.n_spins /= device_count; // spins will be distributed in multiple GPUs (if there is). We hope it is divisible 
    int32_t numBlocks = (param.n_spins + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    uint32_t len0 = 3 * param.n_spins * device_count;
    uint32_t len1 = len0 * param.n_sample_length_scales;
    std::vector<float> M0(len0, 0.f); 
    std::vector<float> M1(len1, 0.f);
    std::vector<float> XYZ0(len0, 0.f);
    std::vector<float> XYZ1(len1, 0.f);

    std::cout << std::string(50, '=') << std::endl;
    for (int16_t fieldmap_no=0; fieldmap_no<param.n_fieldmaps; fieldmap_no++)
    {
        bool hasXYZ0 = false;
        // ========== load files (field-maps, xyz0, m0) ==========
        if(reader::read_fieldmap(filenames.at("fieldmap")[fieldmap_no], fieldmap, mask, param) == false)
            return false;

        if(filenames.at("xyz0")[fieldmap_no].empty() == false)
        {
            if(reader::read_file(filenames.at("xyz0")[fieldmap_no], XYZ0) == false)
                return false;
            
            std::cout << "Checking XYZ0 is not in the mask..." << std::endl;
            uint32_t t = is_masked(XYZ0, mask, &param);
            if(t>0)
            {
                std::cout << ERR_MSG << t << " element(s) of XYZ0 is in the mask. Aborting...!" << std::endl;
                return 1;
            }
            hasXYZ0 = true;
        }

        if(filenames.at("m0")[fieldmap_no].empty() == false)
        {
            if(reader::read_file(filenames.at("m0")[fieldmap_no], M0) == false)
                return false;
        }
        else
        {   // all spins are aligned with B0 (M0 = (0, 0, 1))
            long index = 0;
            std::cout << "Generating M0(0, 0, 1)..." << std::endl;
            std::generate(M0.begin(), M0.end(), [&index](){return (index++ % 3 == 2) ? 1.f : 0.f;});
        }

        if(param.enDebug)
            for(int i=0; i<M0.size()/3; i += M0.size()/3/2)
                std::cout << "M0 of the spin " << i << " = (" << M0[3*i] << ", " << M0[3*i+1] << ", " << M0[3*i+2] << ")" << std::endl;


        for(int i=0; i<3; i++)
            param.scale2grid[i] = (param.fieldmap_size[i] - 1.) / param.sample_length[i];
        
        if (hasXYZ0 && param.n_sample_length_scales > 1)
        {
            std::cout << ERR_MSG << "loading XYZ0 from file while having more than 1 sample length scales is not supported!" << std::endl;
            return false;
        }

        // ========== distributing between devices ==========
        std::vector<float *> d_pFieldMap(device_count, NULL);
        std::vector<float *> d_M0(device_count, NULL), d_M1(device_count, NULL);
        std::vector<float *> d_XYZ1(device_count, NULL), d_XYZ0(device_count, NULL), d_XYZ0_scaled(device_count, NULL);
        std::vector<bool *> d_pMask(device_count, NULL);
        std::vector<simulation_parameters *> d_param(device_count, NULL);
        std::vector<cudaStream_t> streams(device_count, NULL);

        #pragma omp parallel for
        for(int32_t d=0; d<device_count; d++)
        {
            checkCudaErrors(cudaSetDevice(d));            
            checkCudaErrors(cudaStreamCreate(&streams[d]));

            checkCudaErrors(cudaMalloc((void**)&d_param[d],         sizeof(simulation_parameters)));
            checkCudaErrors(cudaMalloc((void**)&d_pFieldMap[d],     sizeof(fieldmap[0]) * fieldmap.size()));   
            checkCudaErrors(cudaMalloc((void**)&d_pMask[d],         sizeof(mask[0]) * mask.size())); 
            checkCudaErrors(cudaMalloc((void**)&d_XYZ0[d],          sizeof(float) * param.n_spins * 3));
            checkCudaErrors(cudaMalloc((void**)&d_XYZ0_scaled[d],   sizeof(float) * param.n_spins * 3));
            checkCudaErrors(cudaMalloc((void**)&d_XYZ1[d],          sizeof(float) * param.n_spins * 3));
            checkCudaErrors(cudaMalloc((void**)&d_M0[d],            sizeof(float) * param.n_spins * 3));
            checkCudaErrors(cudaMalloc((void**)&d_M1[d],            sizeof(float) * param.n_spins * 3));
            
            
            checkCudaErrors(cudaMemcpyAsync(d_pFieldMap[d], fieldmap.data(),        fieldmap.size() * sizeof(fieldmap[0]), cudaMemcpyHostToDevice, streams[d]));
            checkCudaErrors(cudaMemcpyAsync(d_pMask[d],     mask.data(),            mask.size() * sizeof(mask[0]),         cudaMemcpyHostToDevice, streams[d]));
            checkCudaErrors(cudaMemcpyAsync(d_param[d],     &param,                 sizeof(simulation_parameters),         cudaMemcpyHostToDevice, streams[d]));
            checkCudaErrors(cudaMemcpyAsync(d_M0[d],   M0.data()+3*param.n_spins*d, M0.size()/device_count * sizeof(M0[0]),cudaMemcpyHostToDevice, streams[d]));
            
            if(hasXYZ0 == false)
            {   // generate initial spatial position for spins, based on sample_length_ref
                printf("GPU %d) Generating random initial position for spins... ", d);
                generate_initial_position<<<numBlocks, THREADS_PER_BLOCK, 0, streams[d]>>>(d_XYZ0[d], d_param[d], d_pMask[d]);
                gpuCheckKernelExecutionError( __FILE__, __LINE__);
                printf("Done!\n");
            }
            else // copy initial spatial position and magnetization for spins
                checkCudaErrors(cudaMemcpyAsync(d_XYZ0[d], &XYZ0[3*param.n_spins*d], 3 * param.n_spins * sizeof(XYZ0[0]), cudaMemcpyHostToDevice, streams[d]));      
        }

        // ========== run ==========        
        cudaEvent_t start;
        cudaEvent_t end;
        checkCudaErrors(cudaEventCreate(&start));
        checkCudaErrors(cudaEventCreate(&end));
        checkCudaErrors(cudaEventRecord(start));
        
        simulation_parameters param_local;
        memcpy(&param_local, &param, sizeof(simulation_parameters));
        for (int32_t sl = 0; sl < param.n_sample_length_scales; sl++)
        {
            for (int i = 0; i < 3; i++)
            {
                param_local.sample_length[i] = sample_length_scales[sl] * param.sample_length[i];
                param_local.scale2grid[i] = (param_local.fieldmap_size[i] - 1.) / param_local.sample_length[i];
            }

            #pragma omp parallel for
            for (int32_t d = 0; d < device_count; d++)
            {
                if (param.n_sample_length_scales > 1)
                    printf("GPU %d) Simulating sample scale %2d = %8.5f\n", d, sl, sample_length_scales[sl]);
                checkCudaErrors(cudaSetDevice(d));
                cudaMemcpy(d_param[d], &param_local, sizeof(simulation_parameters), cudaMemcpyHostToDevice);

                scale_initial_positions<<<numBlocks, THREADS_PER_BLOCK, 0, streams[d]>>>(d_XYZ0_scaled[d], d_XYZ0[d], sample_length_scales[sl], param.n_spins);
                gpuCheckKernelExecutionError(__FILE__, __LINE__);

                simulation_kernel<<<numBlocks, THREADS_PER_BLOCK, 0, streams[d]>>>(d_param[d], d_pFieldMap[d], d_pMask[d], d_M0[d], d_XYZ0_scaled[d], d_M1[d], d_XYZ1[d]);
                gpuCheckKernelExecutionError(__FILE__, __LINE__);

                int shift = 3*param.n_spins*device_count*sl + 3*param.n_spins*d;
                checkCudaErrors(cudaMemcpyAsync(M1.data()   + shift, d_M1[d]  , sizeof(float) * 3 * param.n_spins, cudaMemcpyDeviceToHost, streams[d]));
                checkCudaErrors(cudaMemcpyAsync(XYZ1.data() + shift, d_XYZ1[d], sizeof(float) * 3 * param.n_spins, cudaMemcpyDeviceToHost, streams[d]));
            }
        }

        float elapsedTime;
        checkCudaErrors(cudaEventRecord(end));
        checkCudaErrors(cudaDeviceSynchronize());
        checkCudaErrors(cudaEventElapsedTime(&elapsedTime, start, end));
        std::cout << "Entire simulation over " << device_count << " GPU(s) took " << std::fixed << std::setprecision(2) << elapsedTime/1000. << " second(s)" << std::endl;

        // ========== clean up GPU ==========
        #pragma omp parallel for
        for(int32_t d=0; d<device_count; d++)
        {
            checkCudaErrors(cudaSetDevice(d));   
            checkCudaErrors(cudaFree(d_param[d]));
            checkCudaErrors(cudaFree(d_pFieldMap[d]));
            checkCudaErrors(cudaFree(d_pMask[d]));
            checkCudaErrors(cudaFree(d_XYZ0[d]));
            checkCudaErrors(cudaFree(d_XYZ0_scaled[d]));
            checkCudaErrors(cudaFree(d_M1[d]));
            checkCudaErrors(cudaFree(d_XYZ1[d]));
            checkCudaErrors(cudaStreamDestroy(streams[d]));            
        }
        checkCudaErrors(cudaEventDestroy(start));
        checkCudaErrors(cudaEventDestroy(end));
        
        // ========== save results ========== 
        output_header hdr(3, param.n_spins, device_count, param.n_sample_length_scales);
        save_output(M1, filenames.at("m1")[fieldmap_no], hdr, sample_length_scales);

        if(filenames.at("xyz1")[fieldmap_no].empty() == false) // do not save if filename is empty
            save_output(XYZ1, filenames.at("xyz1")[fieldmap_no], hdr, sample_length_scales);

        std::cout << std::string(50, '=') << std::endl;
    }
    return true;
}


int main(int argc, char * argv[])
{
    std::vector<std::string> config_files;
    if(argc < 2)
    {
        std::cout << "Usage: " << argv[0] << " <config_file>" << std::endl;
        return 1;
    }
    for(uint8_t i=1; i<argc; i++)
        config_files.push_back(argv[i]);

    std::cout << "Running " << config_files.size() << " simulation(s)..." << std::endl;
    for(uint8_t cnf=0; cnf<config_files.size(); cnf++)
    {
        map<string, vector<string> > filenames = {{"fieldmap", vector<string>()},
                                                  {"xyz0", vector<string>()},
                                                  {"xyz1", vector<string>()},
                                                  {"m0", vector<string>()},
                                                  {"m1", vector<string>()} }; 

        std::vector<float> sample_length_scales;
        simulation_parameters param;

        // ========== read config file ==========
        param.fieldmap_size[0] = param.fieldmap_size[1] = param.fieldmap_size[2] = 0;
        param.sample_length[0] = param.sample_length[1] = param.sample_length[2] = 0.f;
        if(reader::read_config(config_files[cnf], param, sample_length_scales, filenames) == false)
        {
            std::cout << ERR_MSG << "reading config file failed. Aborting...!" << std::endl;
            return 1;
        }

        if (param.seed == 0)
            param.seed = std::random_device{}();

        param.n_timepoints = param.TR / param.dt; // includes start point

        // ========== simulating steady-state signal ==========
        if(param.enSteadyStateSimulation)
        {
            simulate_steady_state(param);
            std::cout<< std::string(30, '-')  << std::endl;
        }

        // ========== Dump Settings ==========
        if(param.enDebug)
        {
            std::cout << "Dumping settings:" << std::endl;
            for (std::map<std::string, std::vector<std::string>>::iterator it=filenames.begin(); it!=filenames.end(); ++it, std::cout << std::endl)
                for (int i = 0; i< it->second.size(); i++)
                    std::cout << it->first << "[" << i << "] = " << it->second.at(i) << std::endl;
            
            for (int32_t i = 0; i < param.n_sample_length_scales; i++)
                std::cout << "Sample length scale " << i << " = " << sample_length_scales[i] << std::endl;

            param.dump();
            std::cout<< std::string(30, '-')  << std::endl;
        }

        if(simulate(param, filenames, sample_length_scales) == false)
            return 1;
    }
    std::cout << "Simulation(s) finished successfully!" << std::endl;
    return 0;
}
