# include <iostream>    // endl
# include <fstream>     // for ofstream
# include <string>      // for string
# include <sstream>     // for stringstream
# include "PFApp.h"
# include "PFAppKernels.h"
# include "../utils/cudaErrorMacros.h" // for cudaCheckErrors & cudaCheckAsyncErrors

using std::string;
using std::stringstream;
using std::cout;
using std::endl;
using std::ofstream;

// -------------------------------------------------------------------------
// Constructor:
// -------------------------------------------------------------------------

PFApp::PFApp(const GetPot& input_params)
    : rng(1234)
{

    // ---------------------------------------
    // Assign variables from 'input_params':
    // ---------------------------------------

    nx = input_params("Domain/nx",1);
    ny = input_params("Domain/ny",1);
    nz = input_params("Domain/nz",1);
    nxyz = nx*ny*nz;
    dx = input_params("Domain/dx",1.0);
    dy = input_params("Domain/dy",1.0);
    dz = input_params("Domain/dz",1.0);
    dt = input_params("Time/dt",1.0);
    numSteps = input_params("Time/nstep",1);
    co = input_params("PFApp/co",0.5);
    M = input_params("PFApp/M",1.0);
    w = input_params("PFApp/w",1.0);
    kap = input_params("PFApp/kap",1.0);
    numOutputs = input_params("Output/numOutputs",1);
    outInterval = numSteps/numOutputs;

    // ---------------------------------------
    // Set up cuda kernel launch variables:
    // ---------------------------------------

    blockSize.x = input_params("GPU/blockSize.x",0);
    blockSize.y = input_params("GPU/blockSize.y",0);
    blockSize.z = input_params("GPU/blockSize.z",0);

    // set default kernel launch parameters
    if(blockSize.x == 0) blockSize.x = 32;
    if(blockSize.y == 0) blockSize.y = 32;
    if(blockSize.z == 0) blockSize.z = 1;

    // calculate the number of blocks to be used (3-D block grid)
    int totalBlockSize = blockSize.x*blockSize.y*blockSize.z;
    blocks.x = (nx + blockSize.x - 1)/blockSize.x;
    blocks.y = (ny + blockSize.y - 1)/blockSize.y;
    blocks.z = (nz + blockSize.z - 1)/blockSize.z;

    // perform some assumption checking
    int numBlocks = blocks.x*blocks.y*blocks.z;
    int totalNumThreads = numBlocks*totalBlockSize;
    if(totalNumThreads < nxyz)
        throw "GPU Kernel Launch setup lacks sufficient threads!\n";
    if(totalBlockSize > 1024)
        throw "Total number of threads per block exceeds 1024";

}



// -------------------------------------------------------------------------
// Destructor:
// -------------------------------------------------------------------------

PFApp::~PFApp()
{

    // ----------------------------------------
    // free up device memory:
    // ----------------------------------------

    cudaFree(c_d);
    cudaFree(df_d);
    cudaFree(cpyBuff_d);
}



// -------------------------------------------------------------------------
// Initialize system:
// -------------------------------------------------------------------------

void PFApp::initSystem()
{

    // ----------------------------------------
    // Initialize the concentration field:
    // ----------------------------------------

    for(size_t i=0;i<nxyz;i++)
        c.push_back(co + 0.1*(rng.uniform()-0.5));

    // ----------------------------------------
    // Allocate memory on device and copy data
    // and copy data from host to device
    // ----------------------------------------

    // allocate memory on device
    size = nxyz*sizeof(double);
    cudaMalloc((void**) &c_d,size);
    cudaCheckErrors("cudaMalloc fail");
    cudaMalloc((void**) &df_d,size);
    cudaCheckErrors("cudaMalloc fail");
    cudaMalloc((void**) &cpyBuff_d,size);
    cudaCheckErrors("cudaMalloc fail");

    // copy concentration array to device
    cudaMemcpy(c_d,&c[0],size,cudaMemcpyHostToDevice);
    cudaCheckErrors("cudaMemcpy H2D fail");

}



// -------------------------------------------------------------------------
// Take one step forward in time:
// -------------------------------------------------------------------------

void PFApp::computeInterval(int interval)
{

    // ----------------------------------------
    //	Set the time step:
    // ----------------------------------------

    current_step = interval*outInterval;

    // ----------------------------------------
    //	Evolve system by solving CH equation:
    // ----------------------------------------

    for(size_t i=0;i<outInterval;i++)
    {
        // calculate the laplacian of c_d and store in df_d
        calculateLap<<<blocks,blockSize>>>(c_d,df_d,nx,ny,nz,dx);
        cudaCheckAsyncErrors("calculateLap kernel fail");
        cudaDeviceSynchronize();
        // calculate the chemical potential and store in df_d
        calculateChemPot<<<blocks,blockSize>>>(c_d,df_d,kap,nx,ny,nz);
        cudaCheckAsyncErrors("calculateChemPot kernel fail");
        cudaDeviceSynchronize();
        // calculate the laplacian of the chemical potential, then update c_d
        // using an Euler update
        lapChemPotAndUpdate<<<blocks,blockSize>>>(c_d,df_d,M,dt,nx,ny,nz,dx);
        cudaDeviceSynchronize();
        cudaCheckAsyncErrors("lapChemPotAndUpdate kernel fail");
    }

    // ----------------------------------------
    //	Copy data back to host for writing:
    // ----------------------------------------

    populateCopyBuffer<<<blocks,blockSize>>>(c_d,cpyBuff_d,nx,ny,nz);
    cudaMemcpyAsync(&c[0],c_d,size,cudaMemcpyDeviceToHost);
    cudaCheckErrors("cudaMemcpyAsync D2H fail");

}



// -------------------------------------------------------------------------
// Write output:
// -------------------------------------------------------------------------

void PFApp::writeOutput(int step)
{

    // -----------------------------------
    // Define the file location and name:
    // -----------------------------------

    ofstream outfile;
    stringstream filenamecombine;
    filenamecombine << "vtkoutput/c_" << step << ".vtk";
    string filename = filenamecombine.str();
    outfile.open(filename.c_str(), std::ios::out);

    // -----------------------------------
    //	Write the 'vtk' file header:
    // -----------------------------------

    string d = "   ";
    outfile << "# vtk DataFile Version 3.1" << endl;
    outfile << "VTK file containing grid data" << endl;
    outfile << "ASCII" << endl;
    outfile << " " << endl;
    outfile << "DATASET STRUCTURED_POINTS" << endl;
    outfile << "DIMENSIONS" << d << nx << d << ny << d << nz << endl;
    outfile << "ORIGIN " << d << 0 << d << 0 << d << 0 << endl;
    outfile << "SPACING" << d << 1.0 << d << 1.0 << d << 1.0 << endl;
    outfile << " " << endl;
    outfile << "POINT_DATA " << nxyz << endl;
    outfile << "SCALARS c float" << endl;
    outfile << "LOOKUP_TABLE default" << endl;

    // -----------------------------------
    //	Write the data:
    // NOTE: x-data increases fastest,
    //       then y-data, then z-data
    // -----------------------------------

    for(size_t k=0;k<nz;k++)
        for(size_t j=0;j<ny;j++)
            for(size_t i=0;i<nx;i++)
            {
                int id = nx*ny*k + nx*j + i;
                outfile << c[id] << endl;
            }

    // -----------------------------------
    //	Close the file:
    // -----------------------------------

    outfile.close();

}



// -------------------------------------------------------------------------
// Run unit tests for this App:
// -------------------------------------------------------------------------

void PFApp::runUnitTests()
{
    bool pass;
    pass = lapKernUnitTest();
    if(pass)
        cout << "\t- lapKernUnitTest -------------- PASSED\n";
    else
        cout << "\t- lapKernUnitTest -------------- FAILED\n";
}



// -------------------------------------------------------------------------
// Unit tests for this App:
// -------------------------------------------------------------------------

bool PFApp::lapKernUnitTest()
{
    // 3X3X3 scalar field with ones except the central node
    double sf[27] = {1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1,1};
    double solution[27] = {0,0,0,0,-1,0,0,0,0,0,-1,0,-1,6,-1,0,-1,0,0,0,0,0,-1,0,0,0,0};
    // allocate space on device
    double* sf_d;
    cudaMalloc((void**) &sf_d,27*sizeof(double));
    cudaCheckErrors("cudaMalloc fail");
    // copy sf to device
    cudaMemcpy(sf_d,sf,27*sizeof(double),cudaMemcpyHostToDevice);
    cudaCheckErrors("cudaMemcpy H2D fail");
    // launch kernel
    dim3 grid(1,1,3);
    dim3 TpB(32,32,1);
    testLap<<<grid,TpB>>>(sf_d,3,3,3,1.0);
    // copy data back to host
    cudaMemcpy(sf,sf_d,27*sizeof(double),cudaMemcpyDeviceToHost);
    cudaCheckErrors("cudaMemcpy D2H fail");
    // print out results
    for(size_t i=0;i<27;i++)
        /* cout << "i=" << i << " sf=" << sf[i] << " sol=" << solution[i] << endl; */
        if( sf[i] != solution[i]) 
        {
            cout << "i=" << i << " sf=" << sf[i] << " sol=" << solution[i] << endl;
            return false;
        }
    return true;
}
