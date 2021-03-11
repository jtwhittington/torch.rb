#pragma once

#include <torch/torch.h>
#include <rice/rice.hpp>

inline VALUE wrap(bool x) {
  return Rice::detail::To_Ruby<bool>::convert(x);
}

inline VALUE wrap(int64_t x) {
  return Rice::detail::To_Ruby<int64_t>::convert(x);
}

inline VALUE wrap(double x) {
  return Rice::detail::To_Ruby<double>::convert(x);
}

inline VALUE wrap(torch::Tensor x) {
  return Rice::detail::To_Ruby<torch::Tensor>::convert(x, true);
}

inline VALUE wrap(torch::Scalar x) {
  return Rice::detail::To_Ruby<torch::Scalar>::convert(x, true);
}

inline VALUE wrap(torch::ScalarType x) {
  return Rice::detail::To_Ruby<torch::ScalarType>::convert(x, true);
}

inline VALUE wrap(torch::QScheme x) {
  return Rice::detail::To_Ruby<torch::QScheme>::convert(x, true);
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  return a;
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor, torch::Tensor> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<2>(x), true)));
  return a;
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<2>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<3>(x), true)));
  return a;
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<2>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<3>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<4>(x), true)));
  return a;
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, int64_t> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<2>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<int64_t>::convert(std::get<3>(x))));
  return a;
}

inline VALUE wrap(std::tuple<torch::Tensor, torch::Tensor, double, int64_t> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<0>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(std::get<1>(x), true)));
  a.push(Object(Rice::detail::To_Ruby<double>::convert(std::get<2>(x))));
  a.push(Object(Rice::detail::To_Ruby<int64_t>::convert(std::get<3>(x))));
  return a;
}

inline VALUE wrap(torch::TensorList x) {
  Array a;
  for (auto& t : x) {
    a.push(Object(Rice::detail::To_Ruby<torch::Tensor>::convert(t, true)));
  }
  return a;
}

inline VALUE wrap(std::tuple<double, double> x) {
  Array a;
  a.push(Object(Rice::detail::To_Ruby<double>::convert(std::get<0>(x))));
  a.push(Object(Rice::detail::To_Ruby<double>::convert(std::get<1>(x))));
  return a;
}
